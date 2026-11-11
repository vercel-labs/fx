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
// session and conversation, the agent list switches between them, and every
// instance takes prompts and session commands the same way, the first one
// included.

const TIMEOUT = 90_000;
const LIST_HINT = "enter switch";

// The agent list's row for instance `number`, and for subagent `name`, which
// sits under its instance behind a branch.
function instanceRow(number: number): RegExp {
  return new RegExp(`^ {2}fx ${number} {2,}`, "m");
}

function subagentRow(name: string): RegExp {
  return new RegExp(`^ {2}[\u251c\u2514] ${name} {2,}`, "m");
}

// The agent list's rows, top to bottom, from a capture with its escapes: each
// one's name, such as "fx 2" or a subagent's own, and whether it is the
// selected row, which the list draws bold and the others dim.
function agentRows(paneEscapes: string): Array<{ name: string; selected: boolean }> {
  const rows: Array<{ name: string; selected: boolean }> = [];
  for (const line of paneEscapes.split("\n")) {
    const plain = line.replace(/\x1b\[[0-9;]*m/g, "");
    const row = /^ {2}(?:(fx \d+|main)|[\u251c\u2514] (\S+)) {2,}\S/.exec(plain);
    if (row) rows.push({ name: (row[1] ?? row[2])!, selected: line.includes("\x1b[1m") });
  }
  return rows;
}

// Waits until the agent list draws `name`'s row selected, then returns the
// pane as text.
async function waitForSelected(session: TmuxSession, name: string, ms = 10_000): Promise<string> {
  const deadline = Date.now() + ms;
  for (;;) {
    const escapes = await session.capturePaneEscapes();
    if (agentRows(escapes).find((row) => row.selected)?.name === name) return await session.capturePane();
    if (Date.now() > deadline) throw new Error(`the agent list never selected ${name}:\n${escapes}`);
    await Bun.sleep(25);
  }
}

// Directions follow the list's order: the instances as they started, each
// followed by its own subagents. A number selects that fx instance.
async function switchAgent(session: TmuxSession, target: "next" | "previous" | number) {
  await session.sendKeys("C-x");
  await session.waitForText(LIST_HINT, 10_000);
  const pane = await session.capturePaneEscapes();
  const rows = agentRows(pane);
  const from = rows.findIndex((row) => row.selected);
  if (from < 0 || rows.length < 2) throw new Error(`no agent list in:\n${pane}`);
  const to = typeof target === "number"
    ? rows.findIndex((row) => row.name === `fx ${target}`)
    : target === "next" ? (from + 1) % rows.length : (from + rows.length - 1) % rows.length;
  if (to < 0) throw new Error(`no fx ${target} row in:\n${pane}`);
  for (let step = 0; step < Math.abs(to - from); step += 1) await session.sendKeys(to > from ? "Down" : "Up");
  await session.sendKeys("Enter");
  await session.waitForPane((value) => !value.includes(LIST_HINT), 10_000);
}

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

// A provider refusal fx can't retry on its own, so the request waits for
// the user.
function rejected(): Response {
  const message = "Your team has restricted access to this provider.";
  return new Response(
    JSON.stringify({ error: { message, type: "no_providers_available", param: { name: "RestrictedProvidersError", message } } }),
    { status: 403, headers: { "content-type": "application/json" } },
  );
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
    // A value of undefined removes the variable, such as FX_MODEL.
    env?: Record<string, string | undefined>;
    // The fake gateway's model catalog.
    models?: unknown[];
    // Filled with every request the fake gateway received, headers included.
    requests?: Array<{ body: string; headers: Headers }>;
    remainOnExit?: boolean;
    // Reuse a profile and workspace across runs; the caller removes them.
    reuse?: { home: string; workspace: string };
  },
  run: (host: Host) => Promise<void>,
): Promise<string[]> {
  const gateway = startDynamicFakeGateway(respond, options.models ? { models: options.models as never } : {});
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
    options.requests?.push(...gateway.requests);
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

// A catalog where every model takes an effort and the fast toggle.
const PREFERENCE_MODELS = ["profile/model", "openai/gpt-5", "other/model"].map((id) => ({
  id,
  type: "language",
  tags: ["reasoning", "tool-use"],
  reasoning_options: [{ type: "effort", values: ["low", "medium", "high"] }],
  fast_options: [{ type: "toggle" }],
}));

// Answers each prompt with DONE_ and its marker.
function echoMarker(body: string): Response {
  const marker = (userTexts(body).at(-1) ?? "").match(/[A-Z][A-Z0-9_]+/)?.[0] ?? "UNMARKED";
  return text(`answer_${marker}`, `DONE_${marker}`);
}

async function promptMarker(session: TmuxSession, marker: string) {
  await session.sendText(marker);
  await session.waitForText(`DONE_${marker}`, 30_000);
  await session.waitForComposer(15_000);
}

// The model, effort, and speed the request for `marker` carried.
function preferencesOf(requests: Array<{ body: string; headers: Headers }>, marker: string) {
  const request = requests.find((value) => (userTexts(value.body).at(-1) ?? "").includes(marker));
  if (!request) return null;
  const body = JSON.parse(request.body);
  return {
    model: request.headers.get("ai-language-model-id"),
    reasoning: body.reasoning ?? null,
    speed: body.providerOptions?.gateway?.speed ?? null,
  };
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

// The host records in `home`, each as the profile of each listed session.
function hostProfiles(home: string): Array<Array<string | null>> {
  const dir = join(home, ".fx", "hosts");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => (JSON.parse(readFileSync(join(dir, name), "utf8")) as { profiles?: Array<string | null> }).profiles ?? []);
}

// Runs three instances in `home`, prompts each as HOST_A, HOST_B, and
// HOST_C, and quits; returns their session ids.
async function saveGroup(home: string, workspace: string): Promise<string[]> {
  await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
    for (const [index, letter] of ["A", "B", "C"].entries()) {
      if (index > 0) {
        await switchAgent(session, index + 1);
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
            await switchAgent(session, index + 1);
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
          expect(pane).toContain("auto · gpt-5");
          expect(pane).toContain(`fx ${index + 1}/3 \u2193`);
          expect(shownAnswers(pane)).toEqual([`HOST_ANSWER_${letter}`]);
        }
        // The first instance is still as it was.
        await switchAgent(session, 1);
        const first = await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
        // The last instance still has its own conversation.
        await switchAgent(session, 3);
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
        await switchAgent(session, "next");
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
    "/launch lists the profiles it can start, and Enter on one launches it",
    async () => {
      await withHost(answerByLetter, {}, async ({ home, session }) => {
        // Saved after fx started: the list reads the profiles when it opens.
        writeProfile(home, "reviewer", { description: "Reviews code for bugs", model: "anthropic/claude-opus-4-7", effort: "high", tools: ["*"] });
        writeProfile(home, "installer", { description: "Installs skills", tools: ["install_skill"] });
        await session.sendLiteral("/launch ");
        // Each row shows the model and effort the instance would start with, as the agent list does, not its
        // description. FX_MODEL wins over the profile's model, as it does at launch; the effort stays the profile's.
        const listed = await session.waitForPane((pane) => /reviewer\s+gpt-5\s+high/.test(pane), 15_000);
        expect(listed).not.toContain("Reviews code for bugs");
        expect(listed).toMatch(/^\s*main\b/m);
        expect(listed).toMatch(/installer\s+gpt-5\s+default\s+custom/);
        expect(listed).not.toContain("read-only");
        await session.sendLiteral("rev");
        await session.waitForPane((pane) => /reviewer\s+gpt-5\s+high/.test(pane) && !/^\s*main\b/m.test(pane), 10_000);
        await session.sendKeys("Enter");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        // The agent list names each instance's profile, and opens on the
        // launched one, which is on screen.
        await session.sendKeys("C-x");
        const list = await session.waitForText(LIST_HINT, 10_000);
        expect(list).toMatch(/^ {2}fx 2 {2,}.* {2,}reviewer(?: {2,}|$)/m);
        expect(agentRows(await session.capturePaneEscapes()).find((row) => row.selected)?.name).toBe("fx 2");
      });
    },
    TIMEOUT,
  );

  test(
    "Delete, then Delete again, in the agent list closes an instance, but never the last one",
    async () => {
      await withHost(answerByLetter, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);

        // The highlight moves to fx 2, and fx 1 stays on screen.
        await session.sendKeys("C-x");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        expect(shownAnswers(await session.waitForText("delete close", 10_000))).toEqual(["HOST_ANSWER_A"]);
        await session.sendKeys("BSpace");
        await session.waitForText("press delete again to close this instance", 10_000);
        await session.sendKeys("BSpace");
        // The list stays open on the instance left, the first, which Delete
        // no longer offers to close: that would end fx.
        const closed = await session.waitForPane((pane) => !/\bfx 2\b/.test(pane) && pane.includes("esc back"), 15_000);
        expect(shownAnswers(closed)).toEqual(["HOST_ANSWER_A"]);
        expect(closed).not.toContain("delete close");
        await session.sendKeys("BSpace");
        await session.sendKeys("BSpace");
        // Keys are handled in order, so the list closing shows both Deletes ran.
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        await session.sendText("HOST_B still here");
        await session.waitForText("HOST_ANSWER_B", 30_000);
      });
    },
    TIMEOUT,
  );

  test(
    "Delete, then Delete again, on the first instance's row closes it, and the next one takes over",
    async () => {
      await withHost(answerByLetter, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);

        // The list opens on the first instance, the one on screen.
        await session.sendKeys("C-x");
        await session.waitForText("delete close", 10_000);
        await session.sendKeys("BSpace");
        await session.waitForText("press delete again to close this instance", 10_000);
        await session.sendKeys("BSpace");
        const closed = await session.waitForPane((pane) => shownAnswers(pane).length === 0 && pane.includes("esc back"), 15_000);
        expect(closed).not.toContain("delete close");
        // The instance left is the one the list goes back to: its row is
        // selected and, as the only instance open, named main.
        expect(agentRows(await session.capturePaneEscapes())).toEqual([{ name: "main", selected: true }]);
        // Esc keeps the instance that took over, not the closed one the list opened on.
        await session.sendKeys("Escape");
        const after = await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        expect(shownAnswers(after)).toEqual([]);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);
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
        await switchAgent(session, "next");
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

        await switchAgent(session, "previous");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B fast");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        order.push("B shown");
        releaseSlow();
        await switchAgent(session, "previous");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/permissions full-access");
        await session.waitForText("mode set to full access", 15_000);
        expect(await runTurn(session, 1, "touch second-ran")).toBe("done");
        expect(existsSync(join(workspace, "second-ran"))).toBe(true);

        // The first is still in ask: the same kind of command asks first.
        await switchAgent(session, "previous");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(await runTurn(session, 3, "touch shared-marker")).toBe("asked");
        await approve(session, 3, "1");
        rmSync(marker);

        // A new session on the second ends only its own approvals.
        await session.waitForComposer(15_000);
        await session.sendText("/new");
        await session.waitForPane((pane) => !pane.includes("PERM_DONE_3") && pane.includes("fx 2/2"), 15_000);
        await switchAgent(session, "previous");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);

        // Close the first: the second takes over as fx 1, as it was.
        await switchAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/close");
        const after = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(after)).toEqual(["HOST_ANSWER_B"]);
        // The closed one is gone from the switch list.
        await switchAgent(session, "next");
        const third = await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(shownAnswers(third)).toEqual([]);
        await switchAgent(session, "next");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        const printed = await quitWith(session, "/exit");
        const second = sessionHolding(home, "HOST_ANSWER_B");
        expect(second).not.toBeNull();
        expect(printed).toContain(`Resume this session with:\nfx --resume ${second}\n`);
        expect(printed).not.toContain(`fx --resume ${sessionHolding(home, "HOST_ANSWER_A")}`);
      });
    },
    TIMEOUT,
  );

  test(
    "an instance with no turn stays out of the host record, and quitting from it names a saved one",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-unsaved-")));
      try {
        let printed = "";
        await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A only");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(500);
          // Only fx 1 saved a session, so there is no group to record.
          expect(hostRecords(home)).toEqual([]);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
          await session.waitForComposer(15_000);
          printed = await quitWith(session, "/exit");
        });
        const saved = sessionHolding(home, "HOST_ANSWER_A");
        expect(saved).not.toBeNull();
        expect(printed).toContain(`Resume this session with:\nfx --resume ${saved}\n`);
        // Resuming it brings back fx 1 alone, with no notice about the others.
        await withHost(answerByLetter, { args: `--resume ${saved}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_A"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
          expect(pane).not.toContain("Couldn't bring back");
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
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
        expect(printed).toContain(`Resume this session with:\nfx --resume ${last}\n`);
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
              await switchAgent(session, index + 1);
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
          await switchAgent(session, 2);
          const second = await session.waitForPane((pane) => pane.includes("fx 2/3") && pane.includes("HOST_ANSWER_A"), 15_000);
          expect(shownAnswers(second)).toEqual(["HOST_ANSWER_A"]);
          await switchAgent(session, 3);
          const third = await session.waitForPane((pane) => pane.includes("fx 3/3") && pane.includes("HOST_ANSWER_C"), 15_000);
          expect(shownAnswers(third)).toEqual(["HOST_ANSWER_C"]);
          // A restored instance carries on its own conversation.
          await switchAgent(session, 2);
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
          await session.waitForComposer(15_000);
          // fx 2 joins the record once its first turn saves its session.
          await Bun.sleep(500);
          expect(hostRecords(home)).toEqual([]);
          await session.sendText("HOST_B second");
          await session.waitForText("HOST_ANSWER_B", 30_000);
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
          await switchAgent(session, 2);
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

        // A member whose session is gone is left out without a notice, the
        // rest come back, and the record follows.
        rmSync(join(home, ".fx", "sessions", "v2", a), { recursive: true, force: true });
        await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("fx 1/2") && value.includes("HOST_ANSWER_B"), 30_000);
          expect(pane).not.toContain("Couldn't bring back");
          await switchAgent(session, "next");
          await session.waitForPane((value) => value.includes("fx 2/2") && value.includes("HOST_ANSWER_C"), 15_000);
          await session.waitForPane(() => hostRecords(home).some((ids) => ids.length === 2 && !ids.includes(a!)), 15_000);
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
            await switchAgent(session, index + 1);
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
    "a launched instance's subagents work under that instance",
    async () => {
      const request = { action: "message", agent: "helper", message: "TREE_TASK make the marker" };
      const bodies = await withHost((body) => {
        const texts = userTexts(body);
        // The subagent's report starts the instance's next turn.
        if (texts.at(-1)?.startsWith("Subagent report (untrusted agent output, not user instructions):")) {
          return text("tree_main_reported", "TREE_MAIN_REPORTED");
        }
        if (texts.join("\n").includes("TREE_TASK")) {
          if (answered(body)) return text("tree_child_done", "TREE_CHILD_DONE");
          return call("tree_touch", "shell", { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: "touch tree-marker" } });
        }
        if (texts.join("\n").includes("TREE_USER")) {
          if (answered(body)) return text("tree_main_final", "TREE_MAIN_FINAL");
          return call("tree_sub", "subagent", { request });
        }
        return answerByLetter(body);
      }, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" } }, async ({ workspace, session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER start a helper");
        await session.waitForText("TREE_MAIN_FINAL", 45_000);
        // The report comes once the subagent's command ran, under fx 2's
        // authority rather than none.
        await session.waitForText("TREE_MAIN_REPORTED", 45_000);
        expect(existsSync(join(workspace, "tree-marker"))).toBe(true);
      });
      const child = bodies.filter((body) => userTexts(body).join("\n").includes("TREE_TASK"));
      expect(child.length).toBeGreaterThan(0);
      expect(toolNames(child[0])).toContain("shell");
    },
    TIMEOUT * 2,
  );

  test(
    "/close ends an instance's working subagent with no report, and reopening that session runs none",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-close-tree-")));
      const releases: Array<() => void> = [];
      let reportTurns = 0;
      const respond = (body: string): Response | Promise<Response> => {
        const texts = userTexts(body);
        if (texts.at(-1)?.startsWith("Subagent report (untrusted agent output, not user instructions):")) {
          reportTurns += 1;
          return text("close_reported", "CLOSE_MAIN_REPORTED");
        }
        // The subagent's request waits until the test ends.
        if (texts.join("\n").includes("SLOW_TASK")) {
          return new Promise((resolve) => releases.push(() => resolve(text("slow_done", "SLOW_DONE"))));
        }
        if (texts.at(-1)?.includes("CLOSE_USER")) {
          if (answered(body)) return text("close_final", "CLOSE_MAIN_FINAL");
          return call("close_sub", "subagent", { request: { action: "message", agent: "slowpoke", message: "SLOW_TASK take your time" } });
        }
        return answerByLetter(body);
      };
      try {
        let closedId = "";
        await withHost(respond, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_A saved");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("CLOSE_USER start a slow helper");
          await session.waitForText("CLOSE_MAIN_FINAL", 45_000);
          await session.waitForPane(() => releases.length > 0 && hostRecords(home).some((ids) => ids.length === 2), 15_000);
          closedId = hostRecords(home).find((ids) => ids.length === 2)![1]!;
          // Closed while slowpoke still works.
          await session.sendText("/close");
          await session.waitForPane(() => hostRecords(home).every((ids) => !ids.includes(closedId)), 15_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(500);
          await session.sendText("/exit");
          await session.waitForSessionEnd(15_000);
        });
        expect(reportTurns).toBe(0);
        // slowpoke's work ended cancelled, and owes the closed tree nothing.
        const log = readFileSync(join(home, ".fx", "sessions", "v2", closedId, "log.jsonl"), "utf8");
        const finishes = log.split("\n").filter((line) => line.includes("child_finished"));
        expect(finishes.length).toBe(1);
        expect(finishes[0]).toContain("cancelled");
        expect(finishes[0]).not.toMatch(/report\\?"\s*:\s*true/);

        // Reopening the closed session by hand brings back its turns and
        // runs no report turn.
        await withHost(respond, { args: `--resume ${closedId}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("CLOSE_MAIN_FINAL"), 30_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(1500);
          expect(await session.capturePane()).not.toContain("CLOSE_MAIN_REPORTED");
        });
        expect(reportTurns).toBe(0);
      } finally {
        for (const release of releases) release();
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new in a launched instance stops its working subagent first, and the instance goes on (D97)",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-switch-tree-")));
      const releases: Array<() => void> = [];
      const respond = (body: string): Response | Promise<Response> => {
        const texts = userTexts(body);
        if (texts.at(-1)?.startsWith("Subagent report (untrusted agent output, not user instructions):")) {
          return text("switch_reported", "SWITCH_MAIN_REPORTED");
        }
        // The subagent's request waits until the test ends.
        if (texts.join("\n").includes("SLOW_TASK")) {
          return new Promise((resolve) => releases.push(() => resolve(text("slow_done", "SLOW_DONE"))));
        }
        if (texts.at(-1)?.includes("SWITCH_USER")) {
          if (answered(body)) return text("switch_final", "SWITCH_MAIN_FINAL");
          return call("switch_sub", "subagent", { request: { action: "message", agent: "slowpoke", message: "SLOW_TASK take your time" } });
        }
        if (texts.at(-1)?.includes("AFTER_NEW")) return text("after_new", "AFTER_NEW_ANSWER");
        return answerByLetter(body);
      };
      try {
        let oldId = "";
        await withHost(respond, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_A saved");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("SWITCH_USER start a slow helper");
          await session.waitForText("SWITCH_MAIN_FINAL", 45_000);
          await session.waitForPane(() => releases.length > 0 && hostRecords(home).some((ids) => ids.length === 2), 15_000);
          oldId = hostRecords(home).find((ids) => ids.length === 2)![1]!;
          // A new session in fx 2 while slowpoke still works.
          await session.sendText("/new");
          await session.waitForText("stopped 1 running subagent task", 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("AFTER_NEW go on");
          await session.waitForText("AFTER_NEW_ANSWER", 30_000);
          // fx 2 moved to its new session, and fx 1 kept its own.
          await session.waitForPane(() => hostRecords(home).some((ids) => ids.length === 2 && ids[1] !== oldId), 15_000);
          await session.sendText("/exit");
          await session.waitForSessionEnd(15_000);
        });
        // slowpoke's work ended cancelled, and slowpoke stays in the old session.
        const log = readFileSync(join(home, ".fx", "sessions", "v2", oldId, "log.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
        const finishes = log.filter((line) => line.kind === "child_finished");
        expect(finishes.map((line) => line.outcome)).toEqual(["cancelled"]);
        expect(JSON.stringify(finishes[0].data ?? "")).not.toContain('\\"closed\\":true');
      } finally {
        for (const release of releases) release();
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a restored later instance lists its subagents under it again, with their conversations",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-restore-tree-")));
      const respond = (body: string) => {
        const texts = userTexts(body);
        if (texts.at(-1)?.startsWith("Subagent report (untrusted agent output, not user instructions):")) {
          return text("keep_reported", "KEEP_MAIN_REPORTED");
        }
        if (texts.join("\n").includes("KEEP_TASK")) return text("keep_child", "KEEP_CHILD_DONE");
        if (texts.at(-1)?.includes("KEEP_USER")) {
          if (answered(body)) return text("keep_final", "KEEP_MAIN_FINAL");
          return call("keep_sub", "subagent", { request: { action: "message", agent: "keeper", message: "KEEP_TASK note it" } });
        }
        return answerByLetter(body);
      };
      try {
        await withHost(respond, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_A saved");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("KEEP_USER start a keeper");
          await session.waitForText("KEEP_MAIN_REPORTED", 45_000);
          await session.sendText("/exit");
          await session.waitForSessionEnd(15_000);
        });
        const group = hostRecords(home).find((ids) => ids.length === 2);
        expect(group).toBeDefined();

        // Resuming the first instance's session brings back fx 2 as a later
        // instance, and keeper comes back under it, idle, with its turn.
        await withHost(respond, { args: `--resume ${group![0]}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("HOST_ANSWER_A"), 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("KEEP_MAIN_REPORTED"), 15_000);
          await switchAgent(session, "next");
          const keeper = await session.waitForPane((pane) => pane.includes("KEEP_CHILD_DONE") && !pane.includes("fx 1/2"), 15_000);
          expect(keeper).toContain("KEEP_TASK");
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a subagent without a profile copies its instance, and one with a profile gets what the profile says",
    async () => {
      let home = "";
      let builderAsked = false;
      const bodies = await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_PLAIN_TASK")) return text("plain_done", "TREE_PLAIN_DONE");
        if (texts.includes("TREE_BUILDER_TASK")) {
          builderAsked = true;
          return text("builder_done", "TREE_BUILDER_DONE");
        }
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
        // Main answers as soon as its call returns, which can be before the
        // builder's own request is out.
        const deadline = Date.now() + 15_000;
        while (!builderAsked && Date.now() < deadline) await Bun.sleep(25);
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
    "a subagent whose profile lists a tool placed behind toolbox keeps toolbox to reach it",
    async () => {
      let childAsked = false;
      const bodies = await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_FINDER_TASK")) {
          // The child's title request carries its task too, before or after
          // its model request; only a request with tools is the child's turn.
          if (toolNames(body).length > 0) childAsked = true;
          return text("finder_done", "TREE_FINDER_DONE");
        }
        const last = userTexts(body).at(-1) ?? "";
        if (last.includes("TREE_USER_FINDER")) {
          if (answered(body)) return text("finder_final", "TREE_FINDER_FINAL");
          return call("finder_sub", "subagent", { request: { action: "message", agent: "finder", profile: "finder", message: "TREE_FINDER_TASK" } });
        }
        return answerByLetter(body);
      }, { args: "--tool-placement glob_files=toolbox", env: { FX_PERMISSION_MODE: "full-access" } }, async ({ home, session }) => {
        writeProfile(home, "finder", { description: "Finds files", tools: ["glob_files"] });
        await session.sendText("TREE_USER_FINDER start a finder");
        await session.waitForText("TREE_FINDER_FINAL", 45_000);
        const deadline = Date.now() + 15_000;
        while (!childAsked && Date.now() < deadline) await Bun.sleep(25);
      });
      // The child is shown what its run was admitted with: glob_files sits
      // behind toolbox for this run, so it keeps toolbox to run it. Its
      // title request carries the task too, but no tools.
      const child = bodies.filter((body) => userTexts(body).join("\n").includes("TREE_FINDER_TASK") && toolNames(body).length > 0);
      expect(child.length).toBeGreaterThan(0);
      expect(toolNames(child[0]!)).toContain("toolbox");
      expect(toolNames(child[0]!)).not.toContain("glob_files");
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
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_LEND_USER write the file");
        // fx 2's own screen, shown by its conversation, holds its subagent's
        // approval, which replaces the footer while it waits.
        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent writer needs permission"), 30_000);

        // The first instance shows only the note that it waits.
        await switchAgent(session, 1);
        const first = await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("writer needs approval"), 15_000);
        expect(first).not.toContain("Subagent writer needs permission");

        // Back on fx 2, the answer there reaches the subagent.
        expect(first).not.toContain("TREE_LEND_USER");
        await switchAgent(session, 2);
        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent writer needs permission"), 15_000);
        await session.sendKeys("1");
        await session.waitForText("TREE_LEND_MAIN_DONE", 30_000);
        expect(readFileSync(join(workspace, "lent.txt"), "utf8")).toBe("TREE_LENT\n");
      });
    },
    TIMEOUT,
  );


  test(
    "an instance's profile decides which MCP servers it can use",
    async () => {
      const fixture = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
      // Open the fixture's tool and run it, or run it without opening it
      // first, then finish.
      const respond = (direct: boolean) => (body: string): Response => {
        const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
        const results = (request.prompt ?? []).filter((message) => message.role === "tool").length;
        if (!direct && results === 0) return call("select_mcp", "toolbox", { open: "mcp_fixture_echo" });
        if (results === (direct ? 0 : 1)) return call("call_mcp", "toolbox", { run: "mcp_fixture_echo", arguments: { text: "hello" } });
        return text("mcp_done", "TREE_MCP_DONE");
      };
      for (const [profile, servers, reaches, direct] of [
        ["nomcp", [], false, false],
        ["withmcp", ["fixture"], true, false],
        ["nomcp", [], false, true],
        ["withmcp", ["fixture"], true, true],
      ] as const) {
        const home = createIsolatedTestHome();
        const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-mcp-")));
        try {
          mkdirSync(join(home, ".fx"), { recursive: true });
          writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({
            // The shell can ask a server for input, and the fixture checks it says so.
            mcp: { fixture: { type: "local", command: [process.execPath, fixture], enabled: true, environment: { FX_MCP_EXPECT_ELICITATION: "both" } } },
          }));
          writeProfile(home, profile, { description: "Checks MCP access", mcp_servers: servers });
          const bodies = await withHost(respond(direct), {
            args: `--profile ${profile}`,
            env: { FX_PERMISSION_MODE: "full-access" },
            reuse: { home, workspace },
          }, async ({ session }) => {
            await session.sendText("TREE_MCP_USER call the fixture");
            await session.waitForText("TREE_MCP_DONE", 45_000);
          });
          // The fixture's answer reaches the model only when the profile
          // names its server, whether or not the model selected the tool,
          // and its toolbox menu lists the server only then.
          expect((bodies.at(-1) ?? "").includes("MODERN_MCP_TOOL_RESULT")).toBe(reaches);
          expect((bodies[0] ?? "").includes("MCP servers\\n- fixture")).toBe(reaches);
        } finally {
          cleanupIsolatedTestHome(home);
          rmSync(workspace, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT * 4,
  );


  test(
    "fx --profile whose tools list one placed behind toolbox starts with toolbox to reach it",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-placed-")));
      try {
        mkdirSync(join(home, ".fx"), { recursive: true });
        writeProfile(home, "finder", { description: "Finds files", tools: ["glob_files"] });
        // The profile is read before the flag places glob_files behind
        // toolbox, so main's tools must be decided again once it is.
        const bodies = await withHost(() => text("answer_placed", "HOST_PLACED_DONE"), {
          args: "--profile finder --tool-placement glob_files=toolbox",
          reuse: { home, workspace },
        }, async ({ session }) => {
          await session.sendText("HOST_PLACED_USER list the files");
          await session.waitForText("HOST_PLACED_DONE", 45_000);
        });
        const first = bodies.find((body) => toolNames(body).length > 0);
        expect(first).toBeDefined();
        expect(toolNames(first!)).toContain("toolbox");
        expect(toolNames(first!)).not.toContain("glob_files");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a launched instance's model and speed changes reach its own turns and no other's",
    async () => {
      for (const launch of ["instances", "launch"] as const) {
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, {
          args: `${launch === "instances" ? "--instances 2 " : ""}--model openai/gpt-5 --effort high --fast`,
          env: { FX_MODEL: undefined },
          models: PREFERENCE_MODELS,
          requests,
        }, async ({ session }) => {
          await promptMarker(session, "FIRST_BEFORE");
          if (launch === "instances") {
            await switchAgent(session, "next");
          } else {
            await session.sendText("/launch");
          }
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/model other/model low normal");
          await session.waitForText("Switched to other/model", 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "SECOND_AFTER");
          await switchAgent(session, "previous");
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "FIRST_AFTER");
        });
        expect(preferencesOf(requests, "SECOND_AFTER"), launch).toEqual({ model: "other/model", reasoning: "low", speed: null });
        expect(preferencesOf(requests, "FIRST_AFTER"), launch).toEqual({ model: "openai/gpt-5", reasoning: "high", speed: "fast" });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/effort sets the effort of the instance on screen and no other's",
    async () => {
      const requests: Array<{ body: string; headers: Headers }> = [];
      await withHost(echoMarker, {
        args: "--instances 2 --model openai/gpt-5 --effort high",
        env: { FX_MODEL: undefined },
        models: PREFERENCE_MODELS,
        requests,
      }, async ({ session }) => {
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/effort low");
        await session.waitForText("Reasoning effort set to", 15_000);
        await session.waitForComposer(15_000);
        await promptMarker(session, "EFFORT_SECOND");
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForComposer(15_000);
        await promptMarker(session, "EFFORT_FIRST");
      });
      expect(preferencesOf(requests, "EFFORT_SECOND")?.reasoning).toBe("low");
      expect(preferencesOf(requests, "EFFORT_FIRST")?.reasoning).toBe("high");
    },
    TIMEOUT,
  );

  test(
    "/launch <profile> uses the profile's model unless the process chose one",
    async () => {
      for (const [fxModel, expected] of [[undefined, "profile/model"], ["openai/gpt-5", "openai/gpt-5"]] as const) {
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: fxModel }, models: PREFERENCE_MODELS, requests }, async ({ home, session }) => {
          writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "PROFILE_LAUNCH");
        });
        const launched = preferencesOf(requests, "PROFILE_LAUNCH");
        expect(launched?.model, String(fxModel)).toBe(expected);
        expect(launched?.reasoning, String(fxModel)).toBe("high");
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/launch <profile> under fx --profile starts in the launched profile's model and effort",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-launch-in-profile-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        writeProfile(home, "plain", { description: "Sets no model or effort" });
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "FIRST_PROFILE");
          for (const [command, count, marker] of [
            ["/launch chooser", 2, "CHOOSER_LAUNCH"],
            ["/launch plain", 3, "PLAIN_LAUNCH"],
            ["/launch", 4, "SAME_LAUNCH"],
          ] as const) {
            await session.sendText(command);
            await session.waitForPane((pane) => pane.includes(`fx ${count}/${count}`), 15_000);
            await session.waitForComposer(15_000);
            await promptMarker(session, marker);
          }
        });
        expect(preferencesOf(requests, "FIRST_PROFILE")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(requests, "CHOOSER_LAUNCH")).toMatchObject({ model: "profile/model", reasoning: "high" });
        // A profile without a model or effort starts from the user's, not
        // the first instance's profile.
        const plain = preferencesOf(requests, "PLAIN_LAUNCH");
        expect(plain?.model).not.toBe("other/model");
        expect(plain?.reasoning).toBeNull();
        // `/launch` alone starts another instance in the launch profile.
        expect(preferencesOf(requests, "SAME_LAUNCH")).toMatchObject({ model: "other/model", reasoning: "low" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a group started in profiles resumes in each profile's model and effort, not the run's --effort",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-resume-profiles-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first --effort medium", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "SAVED_FIRST");
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "SAVED_CHOOSER");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "SAVED_FIRST")).toMatchObject({ model: "other/model", reasoning: "medium" });
        expect(preferencesOf(before, "SAVED_CHOOSER")).toMatchObject({ model: "profile/model", reasoning: "medium" });
        const first = sessionHolding(home, "DONE_SAVED_FIRST")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${first}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_SAVED_FIRST"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_FIRST");
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("DONE_SAVED_CHOOSER"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_CHOOSER");
        });
        // Each session saved its profile's model and effort when it started;
        // `--effort` shaped only the run that passed it.
        expect(preferencesOf(after, "RESUMED_FIRST")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(after, "RESUMED_CHOOSER")).toMatchObject({ model: "profile/model", reasoning: "high" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new under fx --profile keeps a /model choice, and its session resumes in it",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-in-profile-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "PROFILE_TURN");
          await session.sendText("/model profile/model medium normal");
          await session.waitForText("Switched to profile/model", 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_PROFILE_TURN"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "PROFILE_TURN")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(before, "NEW_TURN")).toMatchObject({ model: "profile/model", reasoning: "medium" });
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });
        // Only the session an instance opens with starts in its profile; this
        // one ran in the model and effort chosen before it.
        expect(preferencesOf(after, "RESUMED_TURN")).toMatchObject({ model: "profile/model", reasoning: "medium" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new in a launched profile instance keeps the profile's model and effort, and its session resumes in them",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-launched-")));
      try {
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "LAUNCHED_TURN");
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_LAUNCHED_TURN") && pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "LAUNCHED_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
        expect(preferencesOf(before, "NEW_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });
        expect(preferencesOf(after, "RESUMED_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/effort in a launched instance under FX_MODEL saves the effort but not the run's model",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-effort-env-model-")));
      try {
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: "other/model" }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/launch");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/effort low");
          await session.waitForText("Reasoning effort set to", 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "SAVED_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "SAVED_TURN")).toMatchObject({ model: "other/model", reasoning: "low" });
        const id = sessionHolding(home, "DONE_SAVED_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_SAVED_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });
        // FX_MODEL shaped only the run that set it.
        expect(preferencesOf(after, "RESUMED_TURN")?.model).not.toBe("other/model");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/fast under FX_MODEL changes the run without saving the run's model to settings",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-fast-env-model-")));
      try {
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: "other/model" }, models: PREFERENCE_MODELS, requests, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/fast on");
          await session.waitForText("fast: on", 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "FAST_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(requests, "FAST_TURN")).toMatchObject({ model: "other/model", speed: "fast" });
        // fast mode is saved with its model, so neither outlives this run.
        const settings = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(settings).not.toHaveProperty("models");
        expect(settings).not.toHaveProperty("fast_mode");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/new in a launched instance keeps FX_MODEL for the run without saving it",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-env-model-")));
      try {
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: "other/model" }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/launch");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "LAUNCHED_TURN");
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_LAUNCHED_TURN") && pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "LAUNCHED_TURN")?.model).toBe("other/model");
        expect(preferencesOf(before, "NEW_TURN")?.model).toBe("other/model");
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });
        // FX_MODEL shaped only the run that set it.
        expect(preferencesOf(after, "RESUMED_TURN")?.model).not.toBe("other/model");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "fx --profile <name> uses the profile's model unless the process chose one",
    async () => {
      for (const [args, fxModel, expected] of [
        ["--profile chooser", undefined, "profile/model"],
        ["--profile chooser", "openai/gpt-5", "openai/gpt-5"],
        ["--profile chooser --model other/model", "openai/gpt-5", "other/model"],
      ] as const) {
        const label = `${args} FX_MODEL=${fxModel}`;
        const home = createIsolatedTestHome();
        const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-profile-model-")));
        try {
          writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
          const requests: Array<{ body: string; headers: Headers }> = [];
          await withHost(echoMarker, { args, env: { FX_MODEL: fxModel }, models: PREFERENCE_MODELS, requests, reuse: { home, workspace } }, async ({ session }) => {
            await promptMarker(session, "PROFILE_START");
          });
          const started = preferencesOf(requests, "PROFILE_START");
          expect(started?.model, label).toBe(expected);
          expect(started?.reasoning, label).toBe("high");
        } finally {
          cleanupIsolatedTestHome(home);
          rmSync(workspace, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT * 3,
  );

  test(
    "a subagent calls the MCP tool it selected, and is offered only what its profile admits",
    async () => {
      const fixture = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-mcp-child-")));
      try {
        mkdirSync(join(home, ".fx"), { recursive: true });
        writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({
          mcp: { fixture: { type: "local", command: [process.execPath, fixture], enabled: true, environment: { FX_MCP_EXPECT_ELICITATION: "both" } } },
        }));
        writeProfile(home, "mcp-child", { description: "Uses the fixture", tools: ["read_file", "mcp_select_tool"], mcp_servers: ["fixture"] });
        const bodies = await withHost((body) => {
          const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
          const results = (request.prompt ?? []).filter((message) => message.role === "tool").length;
          if (userTexts(body).join("\n").includes("CHILD_MCP_TASK")) {
            if (results === 0) return call("select_mcp", "toolbox", { open: "mcp_fixture_echo" });
            if (results === 1) return call("call_mcp", "toolbox", { run: "mcp_fixture_echo", arguments: { text: "hello" } });
            return text("child_mcp_done", "CHILD_MCP_DONE");
          }
          // The child's report wakes the parent once its MCP call is done.
          if (userTexts(body).join("\n").includes("CHILD_MCP_DONE")) return text("parent_mcp_done", "PARENT_MCP_DONE");
          if (results === 0) return call("start_child", "subagent", { request: { action: "message", agent: "fixer", profile: "mcp-child", message: "CHILD_MCP_TASK" } });
          return text("parent_mcp_started", "PARENT_MCP_STARTED");
        }, { env: { FX_PERMISSION_MODE: "full-access" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("PARENT_MCP start the child");
          await session.waitForText("PARENT_MCP_DONE", 45_000);
        });
        const child = bodies.filter((body) => userTexts(body).join("\n").includes("CHILD_MCP_TASK"));
        // The fixture's answer reached the child after its call.
        expect(child.at(-1) ?? "").toContain("MODERN_MCP_TOOL_RESULT");
        // The child is offered its profile's tools, and no vision fallback.
        expect(toolNames(child[0])).toEqual(["read_file", "toolbox"]);
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );


  test(
    "resuming brings each instance back in the profile it ran in",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-profiles-")));
      try {
        writeProfile(home, "limited", { description: "Reads only", tools: ["read_file"] });
        // fx 1 runs in main, and fx 2 is launched in `limited`.
        await withHost(answerByLetter, { remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A first run");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await session.waitForComposer(15_000);
          await session.sendText("/launch limited");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_B first run");
          await session.waitForText("HOST_ANSWER_B", 30_000);
          await quitWith(session, "/exit");
        });
        const [a, b] = ["A", "B"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
        expect(hostRecords(home)).toEqual([[a, b]]);
        expect(hostProfiles(home)).toEqual([["main", "limited"]]);

        // Resuming the limited one brings it back first and still limited,
        // and the other in main.
        const bodies = await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("HOST_ANSWER_B"), 30_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_C on the limited one");
          await session.waitForText("HOST_ANSWER_C", 30_000);
          await session.waitForComposer(15_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("HOST_ANSWER_A"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_D on the main one");
          await session.waitForText("HOST_ANSWER_D", 30_000);
        });
        const limited = bodies.find((body) => letterOf(body) === "C")!;
        const unlimited = bodies.find((body) => letterOf(body) === "D")!;
        expect(toolNames(limited)).toContain("read_file");
        expect(toolNames(limited)).not.toContain("shell");
        expect(toolNames(unlimited)).toContain("shell");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a lone instance in a profile resumes in it, unless --profile names another",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-lone-profile-")));
      try {
        writeProfile(home, "limited", { description: "Reads only", tools: ["read_file"] });
        await withHost(answerByLetter, { args: "--profile limited", remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A only run");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await quitWith(session, "/exit");
        });
        const a = sessionHolding(home, "HOST_ANSWER_A")!;
        expect(hostRecords(home)).toEqual([[a]]);
        expect(hostProfiles(home)).toEqual([["limited"]]);
        const resumed = async (args: string, letter: string) => {
          const bodies = await withHost(answerByLetter, { args, reuse: { home, workspace } }, async ({ session }) => {
            await session.waitForPane((pane) => pane.includes("HOST_ANSWER_A"), 30_000);
            await session.waitForComposer(15_000);
            await session.sendText(`HOST_${letter} resumed`);
            await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
          });
          return toolNames(bodies.find((body) => letterOf(body) === letter)!);
        };
        expect(await resumed(`--resume ${a}`, "B")).not.toContain("shell");
        expect(await resumed(`--profile main --resume ${a}`, "C")).toContain("shell");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a hidden instance's waiting note names it by number, before the agent indicator",
    async () => {
      await withHost((body) => {
        if (answered(body)) return text("note_done", "NOTE_DONE");
        return call("note_shell", "shell", { request: { action: "run", command: "rm -rf ./nothing-here" } });
      }, { instances: 3, env: { FX_PERMISSION_MODE: "ask" } }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("NOTE_THREE go");
        await session.waitForPane((pane) => pane.includes("rm -rf"), 15_000);
        // fx 3 waits; on fx 1 the note names it, then the indicator.
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 3 needs approval · fx 1/3 \u2193"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("NOTE_ONE go");
        await session.waitForPane((pane) => pane.includes("rm -rf"), 15_000);
        // From fx 2, fx 1 comes first.
        await switchAgent(session, "next");
        const pane = await session.waitForPane((value) => value.includes("fx 2/3") && value.includes("need you"), 15_000);
        expect(pane).toContain("fx 1 and 1 more need you · fx 2/3 \u2193");
        expect(pane).not.toContain("main");
      });
    },
    TIMEOUT,
  );


  test(
    "/agents lists the open agents, and Enter keeps the one shown",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        // Ctrl+X opens the list in place of an open panel, which holds
        // typed keys.
        await session.sendText("/status");
        await session.waitForPane((pane) => pane.includes("Step limit"), 15_000);
        await session.sendKeys("C-x");
        const list = await session.waitForPane((pane) => instanceRow(3).test(pane), 15_000);
        expect(list).not.toContain("Step limit");
        expect(list).toContain("Agents 3");
        expect(list).toMatch(instanceRow(1));
        expect(list).toMatch(/^ {2}fx 2 {2,}new session {2,}idle {2,}main {2,}\S/m);
        expect(list).toMatch(/^ {2}fx 3 {2,}new session {2,}idle {2,}main {2,}\S/m);
        expect(list).toContain(LIST_HINT);
        // The list opens on the agent on screen.
        expect(agentRows(await session.capturePaneEscapes())).toEqual([
          { name: "fx 1", selected: true },
          { name: "fx 2", selected: false },
          { name: "fx 3", selected: false },
        ]);
        // Esc closes it.
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !instanceRow(3).test(pane), 15_000);
        // ↓↓ moves the highlight to fx 3, and Enter shows it.
        await session.sendText("/agents");
        await session.waitForPane((pane) => instanceRow(3).test(pane), 15_000);
        await session.sendKeys("Down");
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForPane((pane) => pane.includes("fx 3/3") && !instanceRow(3).test(pane), 15_000);
        await session.waitForComposer(15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "moving through the agent list moves only the highlight, and the screen changes on Enter",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await session.waitForComposer(15_000);
        await session.sendKeys("Down");
        await session.waitForText(LIST_HINT, 10_000);
        // Down, Down, Up, and Down past the last row: each move lands the
        // highlight, and fx 1's conversation stays on screen. The list's hint
        // row takes the footer's place while it is open.
        for (const [key, name] of [["Down", "fx 2"], ["Down", "fx 3"], ["Up", "fx 2"], ["Down", "fx 3"], ["Down", "fx 3"]] as const) {
          await session.sendKeys(key);
          const pane = await waitForSelected(session, name);
          expect(shownAnswers(pane)).toEqual(["HOST_ANSWER_A"]);
        }
        // Esc closes the list on fx 1, as it was.
        await session.sendKeys("Escape");
        const kept = await session.waitForPane((pane) => !pane.includes(LIST_HINT), 10_000);
        expect(kept).toContain("fx 1/3");
        expect(shownAnswers(kept)).toEqual(["HOST_ANSWER_A"]);
        // Enter on a row switches to it.
        await session.sendKeys("C-x");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        await session.sendKeys("Down");
        await waitForSelected(session, "fx 3");
        await session.sendKeys("Enter");
        const shown = await session.waitForPane((pane) => pane.includes("fx 3/3") && !pane.includes(LIST_HINT), 15_000);
        expect(shownAnswers(shown)).toEqual([]);
      });
    },
    TIMEOUT,
  );

  test(
    "down on an empty composer opens the agent list while another agent is open, and not with one",
    async () => {
      await withHost(answerByLetter, {}, async ({ session }) => {
        await session.sendKeys("Down");
        await Bun.sleep(500);
        expect(await session.capturePane()).not.toContain(LIST_HINT);
        await session.sendText("/launch");
        await session.waitForPane((pane) => pane.includes("fx 2/2 \u2193"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendKeys("Down");
        const list = await session.waitForPane((pane) => instanceRow(2).test(pane), 15_000);
        expect(list).toMatch(instanceRow(1));
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !instanceRow(2).test(pane), 15_000);

        // In a draft of several lines, down stays in the draft and Option+Up
        // moves up a paragraph.
        await session.sendLiteral("first");
        await session.sendKeys("M-Enter");
        await session.sendLiteral("second");
        await session.waitForPane((pane) => pane.includes("second") && pane.includes("fx 2/2 · ctrl+x"), 10_000);
        await session.sendKeys("Down");
        await session.sendKeys("M-Up");
        await session.sendLiteral("Z");
        const moved = await session.waitForPane((pane) => pane.includes("Z"), 10_000);
        expect(moved).not.toContain(LIST_HINT);
        expect(moved).not.toContain("secondZ");
      });
    },
    TIMEOUT,
  );

  test(
    "the agent list puts each instance's subagents under it and opens on the agent on screen",
    async () => {
      await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("LIST_TASK")) return text("list_child", "LIST_CHILD_DONE");
        if (texts.includes("LIST_USER")) {
          if (answered(body)) return text("list_main_final", "LIST_MAIN_FINAL");
          return call("list_sub", "subagent", { request: { action: "message", agent: "helper", message: "LIST_TASK look" } });
        }
        return answerByLetter(body);
      }, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" } }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("LIST_USER start a helper");
        await session.waitForText("LIST_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);
        // fx 1's subagent comes right after it when switching.
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("helper \u00b7 "), 15_000);
        await session.sendKeys("C-x");
        const list = await session.waitForPane((pane) => subagentRow("helper").test(pane) && pane.includes(LIST_HINT), 15_000);
        expect(list).toContain("Agents 3");
        // The helper's branch ends at it: fx 1 has no other subagent.
        expect(list).toMatch(/^ {2}\u2514 helper {2,}/m);
        expect(agentRows(await session.capturePaneEscapes())).toEqual([
          { name: "fx 1", selected: false },
          { name: "helper", selected: true },
          { name: "fx 2", selected: false },
        ]);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("helper \u00b7 "), 15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a hidden instance that finishes is named in the footer until it is shown",
    async () => {
      await withHost(async (body) => {
        if (userTexts(body).join("\n").includes("HOST_S")) await Bun.sleep(1500);
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_S slow work");
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForPane((pane) => pane.includes("fx 2 finished · fx 1/2 \u2193"), 15_000);
        await session.sendText("/agents");
        const list = await session.waitForPane((pane) => instanceRow(2).test(pane), 15_000);
        expect(list).toMatch(/^ {2}fx 2 {2,}.* {2,}finished {2,}main {2,}\S/m);
        await session.sendKeys("Escape");
        // Showing it clears the note.
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("HOST_ANSWER_S"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await Bun.sleep(300);
        expect(await session.capturePane()).not.toContain("finished ·");
      });
    },
    TIMEOUT,
  );

  test(
    "a hidden instance whose request waits for you is named in the footer and the list",
    async () => {
      await withHost((body) => {
        if (userTexts(body).join("\n").includes("HOST_R")) return rejected();
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_R refused");
        // The provider refuses it, so it waits on fx 2's screen for Esc.
        await session.waitForText("The provider rejected this request · press Esc", 30_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("fx 2 needs you · fx 1/2 \u2193"), 15_000);
        await session.sendText("/agents");
        const list = await session.waitForPane((pane) => instanceRow(2).test(pane), 15_000);
        expect(list).toMatch(/^ {2}fx 2 {2,}.* {2,}needs you {2,}main {2,}\S/m);
        await session.sendKeys("Escape");
        // Esc on its own screen ends the request, and the note goes.
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("press Esc"), 15_000);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("The provider rejected this request"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await Bun.sleep(300);
        expect(await session.capturePane()).not.toContain("needs you");
      });
    },
    TIMEOUT,
  );

});
