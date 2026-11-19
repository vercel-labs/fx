// The compact transcript tells what each group of tool calls did and how it
// ended: a header that names the group's main event, one row for calls that
// repeat one task, a reason line under a failed call, and a recap on the turn
// summary.
import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  CHILD_MARKER,
  createStoryRoot,
  sh,
  startStoryGateway,
  type StoryRoot,
  type StoryStep,
} from "./fixtures/story-model";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 90_000;

const FAILING_BUILD: StoryStep[] = [
  {
    at: 0,
    text: "I will check the repo state, then run the build.",
    calls: [sh("sh check.sh status"), sh("sh check.sh remote"), sh("sh build.sh")],
  },
  {
    at: 3,
    text: "The build fails in src/main.ts: start() still passes three arguments.",
    calls: [
      { name: "grep_files", input: { pattern: "createWindow(", path: "desktop/src" } },
      { name: "read_file", input: { path: "desktop/src/window.ts" } },
    ],
  },
  {
    at: 5,
    calls: [{
      name: "edit_file",
      input: {
        path: "desktop/src/main.ts",
        old_string: "  const win = createWindow(url, 1280, 800);",
        new_string: "  const win = createWindow({ url, width: 1280, height: 800 });",
      },
    }],
  },
  { at: 6, calls: [sh("sh build.sh")] },
  { at: 7, text: "Fixed the build." },
];

const REPEATS: StoryStep[] = [
  { at: 0, text: "I will run the tests.", calls: [sh("sh test.sh")] },
  { at: 1, calls: [sh("sh test.sh")] },
  { at: 2, calls: [sh("sh test.sh")] },
  {
    at: 3,
    text: "One test is flaky. I will read the code it covers.",
    calls: [{ name: "read_file", input: { path: "desktop/src/main.ts", start_line: 1, line_count: 5 } }],
  },
  { at: 4, calls: [{ name: "read_file", input: { path: "desktop/src/main.ts", start_line: 6, line_count: 5 } }] },
  { at: 5, calls: [{ name: "read_file", input: { path: "desktop/src/main.ts", start_line: 11, line_count: 6 } }] },
  { at: 6, text: "The tests pass on the third run." },
];

// Two shell requests the tool refuses before running anything, as a model
// sends them, then the fixed request, which runs the same steps.
const REFUSED_REQUESTS: StoryStep[] = [
  {
    at: 0,
    calls: [{
      name: "shell",
      input: {
        command: "ls -l . 2>/dev/null && printf ok | head -1",
        profile: "clean",
        tty: true,
        shell: { kind: "executable", path: "/bin/sh", clean_start: true },
      },
    }],
  },
  {
    at: 1,
    calls: [{
      name: "shell",
      input: {
        command: "ls -l .; printf ok | head -1",
        shell: { kind: "executable", path: "/bin/sh", clean_start: true },
      },
    }],
  },
  { at: 2, calls: [sh("ls -l .; printf ok | head -1")] },
  { at: 3, text: "The folder is listed." },
];

// A turn that ends on a request the shell refused, which the model never
// fixed.
const REFUSED_LAST: StoryStep[] = [
  { at: 0, calls: [sh("printf done")] },
  { at: 1, calls: [REFUSED_REQUESTS[0].calls![0]] },
  { at: 2, text: "I could not list the folder." },
];

// Two commands fail, the last of them too.
const LAST_TWO_FAILED: StoryStep[] = [
  { at: 0, calls: [sh("printf ok"), sh("ls missing-one"), sh("cat missing-two")] },
  { at: 3, text: "Both files are missing." },
];

// A command whose here-document holds an apostrophe, which is no shell quote.
const HERE_DOCUMENT: StoryStep[] = [
  { at: 0, calls: [sh("cat > notes.md <<'EOF'\nThe model's notes\nEOF\nwc -l notes.md")] },
  { at: 1, text: "The notes are saved." },
];

// A command that prints code naming an error, then fails on its own.
const PRINTED_CODE_THEN_FAILED: StoryStep[] = [
  { at: 0, calls: [sh("printf 'const error_code = 1;\\nroot.get(\"error\")\\n'; ls missing-file")] },
  { at: 1, text: "The file is missing." },
];

const SUBAGENTS: StoryStep[] = [
  {
    at: 0,
    text: "I will ask two subagents to check the change.",
    calls: [
      { name: "subagent", input: { action: "message", agent: "reviewer", message: `${CHILD_MARKER} Review the createWindow change.` } },
      { name: "subagent", input: { action: "message", agent: "tester", message: `${CHILD_MARKER} Run the desktop tests.` } },
    ],
  },
  { at: 2, calls: [{ name: "subagent", input: { action: "wait" } }] },
  { at: 3, calls: [{ name: "subagent", input: { action: "wait" } }] },
  { at: 4, calls: [{ name: "subagent", input: { action: "status" } }] },
  { at: 5, text: "Both subagents finished." },
];

const SEARCHES: StoryStep[] = [
  {
    at: 0,
    text: "I will look for the createWindow callers.",
    calls: [
      { name: "grep_files", input: { pattern: "createWindow", path: "desktop/src" } },
      { name: "grep_files", input: { pattern: "createWindow", path: "desktop" } },
      { name: "glob_files", input: { pattern: "*.ts", path: "desktop" } },
    ],
  },
  { at: 3, text: "Two files use createWindow." },
];

const EXPLORE: StoryStep[] = [
  {
    at: 0,
    text: "I will read the window code and look for its callers.",
    calls: [
      { name: "read_file", input: { path: "desktop/src/window.ts", start_line: 1, line_count: 5 } },
      { name: "grep_files", input: { pattern: "createWindow", path: "desktop/src" } },
      { name: "read_file", input: { path: "desktop/src/main.ts" } },
      { name: "read_file", input: { path: "desktop/src/window.ts", start_line: 6, line_count: 5 } },
      { name: "grep_files", input: { pattern: "BrowserWindow", path: "desktop/src" } },
      sh("sh check.sh status"),
    ],
  },
  { at: 6, text: "createWindow builds the main window." },
];

const HOSTILE: StoryStep[] = [
  { at: 0, text: "I will run the script.", calls: [sh("sh hostile.sh")] },
  { at: 1, text: "The script failed." },
];

const roots: StoryRoot[] = [];
const sessions: TmuxSession[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root.root, { recursive: true, force: true });
});

function storyEnv(root: StoryRoot, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-tool-story-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    NO_COLOR: "1",
  };
}

async function runStory(
  steps: StoryStep[],
  options: {
    prompt: string;
    finalText: string;
    width?: number;
    height?: number;
    settings?: Record<string, unknown>;
    childReply?: (task: string) => string | Promise<string>;
  },
) {
  const root = createStoryRoot(options.settings);
  roots.push(root);
  const gateway = startStoryGateway(steps, options.childReply);
  gateways.push(gateway);
  const session = await TmuxSession.create({
    cwd: root.workspace,
    env: storyEnv(root, gateway),
    width: options.width ?? 110,
    height: options.height ?? 60,
  });
  sessions.push(session);
  await session.waitForComposer();
  await session.sendText(options.prompt);
  await session.waitForText(options.finalText, TIMEOUT);
  const pane = await session.waitForComposer(TIMEOUT);
  return { root, gateway, session, pane };
}

function paneLines(pane: string): string[] {
  return pane.split("\n").map((line) => line.trimEnd());
}

/** A group's header line and every line under it up to the blank line that ends it. */
function group(lines: string[], header: string | RegExp): string[] {
  const start = lines.findIndex((line) => typeof header === "string" ? line === header : header.test(line));
  if (start < 0) throw new Error(`no group header ${String(header)} in:\n${lines.join("\n")}`);
  const end = lines.findIndex((line, index) => index > start && line === "");
  return lines.slice(start, end < 0 ? undefined : end);
}

function treeRows(block: string[]): string[] {
  return block.filter((line) => line.startsWith("├ ") || line.startsWith("└ "));
}

test.skipIf(!tmuxAvailable())(
  "a failing build tells its story in the default view and after resume",
  async () => {
    const { root, gateway, session, pane } = await runStory(FAILING_BUILD, {
      prompt: "the desktop build is broken, can you fix it?",
      finalText: "Fixed the build.",
    });
    const lines = paneLines(pane);

    const checks = group(lines, "● ran commands ✗");
    // The two passing checks share a row by their step; the failure keeps
    // its own, with the error's line after it.
    expect(treeRows(checks)).toEqual([
      "├ ran sh check.sh",
      expect.stringMatching(/^└ .*sh build\.sh · Expected 1 arguments, but got 3\.$/),
    ]);
    expect(checks.some((line) => line.includes("✗ exit"))).toBe(false);

    // Edits come first; the other kinds tie, and the fourth is "more".
    const fix = group(lines, "● edited a file, ran a command, read a file, and more ✓");
    const fixRows = treeRows(fix);
    expect(fixRows).toHaveLength(4);
    expect(fixRows[0]).toStartWith("├ searched");
    // A read shows the file by name.
    expect(fixRows[1]).toBe("├ read window.ts");
    // An edit shows the file by name, with its counts.
    expect(fixRows[2]).toBe("├ edited main.ts +1/-1");
    expect(fixRows[3]).toBe("└ ran sh build.sh");
    expect(lines.some((line) => /^ {2}1 file changed \+1 -1 · ran 4 commands · /.test(line))).toBe(true);
    expect(lines.some((line) => / tool calls? · /.test(line))).toBe(false);

    // The same session, reopened, renders the same story.
    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("Fixed the build.", TIMEOUT);
    const resumedLines = paneLines(await resumed.waitForComposer(TIMEOUT));
    expect(group(resumedLines, "● ran commands ✗")).toEqual(checks);
    expect(group(resumedLines, "● edited a file, ran a command, read a file, and more ✓")).toEqual(fix);
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "calls after a message sent into an open turn show under that message, also after resume",
  async () => {
    const root = createStoryRoot();
    roots.push(root);
    writeFileSync(join(root.workspace, "README.md"), "hello\n");
    const gateway = startFakeGateway([
      fakeGatewaySse([
        { type: "tool-call", toolCallId: "read_1", toolName: "read_file", input: { path: "README.md" } },
        {
          type: "tool-call",
          toolCallId: "edit_1",
          toolName: "edit_file",
          input: { path: "README.md", old_string: "NOT_THERE", new_string: "x" },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      // The next request fails and leaves the turn open, so the next message
      // joins that turn.
      new Response(
        JSON.stringify({ error: { message: "STORY_BAD_REQUEST", type: "invalid_request_error" } }),
        { status: 400, headers: { "content-type": "application/json" } },
      ),
      fakeGatewaySse([
        { type: "tool-call", toolCallId: "read_2", toolName: "read_file", input: { path: "README.md" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewayFinalText("The readme says hello."),
    ]);
    gateways.push(gateway);
    const session = await TmuxSession.create({
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(session);
    await session.waitForComposer();
    await session.sendText("Edit the readme.");
    await session.waitForText("STORY_BAD_REQUEST", TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Read it again.");
    await session.waitForText("The readme says hello.", TIMEOUT);

    const expectReadUnderMessage = (lines: string[]) => {
      const message = lines.findIndex((line) => line.includes("read it again."));
      expect(message).toBeGreaterThan(0);
      // The first read keeps its own row, without the later one.
      expect(lines.slice(0, message)).toContain("├ read README.md");
      // The failed edit names its file, also when the saved session is
      // read back.
      expect(lines.slice(0, message)).toContain("└ Couldn't edit README.md");
      expect(lines.some((line) => line.includes("· 2 parts"))).toBe(false);
      // The later read shows under the message that asked for it.
      expect(lines.slice(message + 1)).toContain("● read README.md");
    };
    expectReadUnderMessage(paneLines(await session.waitForComposer(TIMEOUT)));

    // The message is saved as steering, which resumes as a user message.
    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("The readme says hello.", TIMEOUT);
    expectReadUnderMessage(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "shell requests refused before they ran read as the model's mistake, also after resume",
  async () => {
    const { root, gateway, session, pane } = await runStory(REFUSED_REQUESTS, {
      prompt: "list the folder",
      finalText: "The folder is listed.",
    });
    const expectFixedRequest = (lines: string[]) => {
      // The fixed request says which try it was. The refused ones never ran,
      // so they get no row, no failure count, and no "run" of the command.
      expect(lines).toContain("● Ran ls, printf · 3rd try ✓");
      expect(lines.some((line) => /Failed|invalid field|Couldn't run|passed on|failed/.test(line))).toBe(false);
    };
    expectFixedRequest(paneLines(pane));

    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("The folder is listed.", TIMEOUT);
    expectFixedRequest(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "a header's failure count takes in the last command, also after resume",
  async () => {
    const { root, gateway, session, pane } = await runStory(LAST_TWO_FAILED, {
      prompt: "read both files",
      finalText: "Both files are missing.",
    });
    const expectCount = (lines: string[]) => {
      // The mark is the last command's; the count is every failed row.
      const header = lines.find((line) => line.startsWith("● ") && line.includes("✗"));
      expect(header).toBeDefined();
      expect(header!).toEndWith("✗ · 2 failed");
      expect(lines.filter((line) => /^[├└] (Exited|Couldn't)/.test(line))).toHaveLength(2);
    };
    expectCount(paneLines(pane));

    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("Both files are missing.", TIMEOUT);
    expectCount(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "a refused shell request the turn ended on says why, also after resume",
  async () => {
    const { root, gateway, session, pane } = await runStory(REFUSED_LAST, {
      prompt: "list the folder",
      finalText: "I could not list the folder.",
    });
    const expectReason = (lines: string[]) => {
      // Like any failure a turn ends on, its row says why, as core counted
      // it, but not the error the model got.
      expect(lines).toContain("└ Couldn't run ls, printf · 2 invalid fields");
      expect(lines.some((line) => /Choose either|Failed /.test(line))).toBe(false);
    };
    expectReason(paneLines(pane));

    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("I could not list the folder.", TIMEOUT);
    expectReason(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "a command with a here-document shows its steps, also after resume",
  async () => {
    const { root, gateway, session, pane } = await runStory(HERE_DOCUMENT, {
      prompt: "save the notes",
      finalText: "The notes are saved.",
    });
    const expectSteps = (lines: string[]) => {
      // The document's text is not shell words, so the row shows the steps.
      expect(lines).toContain("● Ran cat, wc ✓");
      expect(lines.some((line) => line.includes("model's") || line.includes("<<"))).toBe(false);
    };
    expectSteps(paneLines(pane));

    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("The notes are saved.", TIMEOUT);
    expectSteps(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "a failed command says the error it reported, not code it printed",
  async () => {
    const { pane } = await runStory(PRINTED_CODE_THEN_FAILED, {
      prompt: "check the file",
      finalText: "The file is missing.",
    });
    const lines = paneLines(pane);
    // The reason is ls's own message, not a printed line that names "error",
    // without the words that say who spoke, and at most 40 columns.
    const row = lines.find((line) => /^● Exited \d+ printf, ls · /.test(line));
    expect(row).toBeDefined();
    const reason = row!.replace(/^● Exited \d+ printf, ls · /, "").replace(/ ✗$/, "");
    expect(reason).toMatch(/^(No such file or directory|cannot access 'missing-file': No such f…)$/);
    expect([...reason].length).toBeLessThanOrEqual(40);
    expect(lines.some((line) => line.includes("error_code") || line.includes('get("error")'))).toBe(false);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "a second message to an agent joins its row while the message streams",
  async () => {
    const encoder = new TextEncoder();
    let timer: ReturnType<typeof setInterval> | undefined;
    let sendRest: (() => void) | undefined;
    const message = `${CHILD_MARKER} Look at the window change too.`;
    const held = () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            const send = (event: object) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
            send({ type: "tool-input-start", id: "second_message", toolName: "subagent" });
            // The agent is whole; its message is not.
            send({ type: "tool-input-delta", id: "second_message", delta: '{"action":"message","agent":"reviewer","message":"' });
            timer = setInterval(() => controller.enqueue(encoder.encode(": hold-message\n\n")), 50);
            sendRest = () => {
              clearInterval(timer);
              send({ type: "tool-input-delta", id: "second_message", delta: `${JSON.stringify(message).slice(1)}}` });
              send({ type: "tool-input-end", id: "second_message" });
              send({ type: "tool-call", toolCallId: "second_message", toolName: "subagent", input: { action: "message", agent: "reviewer", message } });
              send({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
              controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              controller.close();
            };
          },
          cancel() {
            clearInterval(timer);
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
    const steps: StoryStep[] = [
      { at: 0, calls: [{ name: "subagent", input: { action: "message", agent: "reviewer", message: `${CHILD_MARKER} Review the createWindow change.` } }] },
      { at: 1, calls: [{ name: "read_file", input: { path: "desktop/src/main.ts" } }] },
      { at: 2, response: held },
      { at: 3, text: "Asked the reviewer twice." },
    ];
    const root = createStoryRoot();
    roots.push(root);
    const gateway = startStoryGateway(steps, () => "Reviewed.");
    gateways.push(gateway);
    const session = await TmuxSession.create({ cwd: root.workspace, env: storyEnv(root, gateway), width: 110, height: 60 });
    sessions.push(session);
    await session.waitForComposer();
    await session.sendText("ask the reviewer twice");
    const rowsOf = (pane: string) => paneLines(pane).filter((line) => /^(●|├|└) /.test(line));
    await session.waitForText("Read main.ts", TIMEOUT);
    // While the second message streams, it joins the reviewer's row at once
    // instead of showing a row of its own that folds into it later, so the
    // group's rows never go down.
    const frames: string[][] = [];
    for (let i = 0; i < 15; i += 1) {
      frames.push(rowsOf(await session.capturePane()));
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    sendRest?.();
    for (let i = 0; i < 200; i += 1) {
      const pane = await session.capturePane();
      frames.push(rowsOf(pane));
      if (pane.includes("Asked the reviewer twice.")) break;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    // The first group's tree rows, which sit right under its header.
    const firstGroupRows = (frame: string[]) => {
      const start = frame.findIndex((row) => row.startsWith("● "));
      const rows: string[] = [];
      for (const row of frame.slice(start + 1)) {
        if (!/^(├|└) /.test(row)) break;
        rows.push(row);
      }
      return rows;
    };
    for (let i = 1; i < frames.length; i += 1) {
      expect(firstGroupRows(frames[i]).length).toBeGreaterThanOrEqual(firstGroupRows(frames[i - 1]).length);
    }
    expect(frames.every((frame) => frame.filter((row) => /^(├|└) .*reviewer/.test(row)).length <= 1)).toBe(true);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "a report that joins a turn after its calls keeps a line of its own, also after resume",
  async () => {
    const encoder = new TextEncoder();
    let timer: ReturnType<typeof setInterval> | undefined;
    let sendRead: (() => void) | undefined;
    let readHeld = () => {};
    const readStarted = new Promise<void>((resolve) => (readHeld = resolve));
    // The read's reply waits until the reviewer's report has joined the
    // open turn, so the turn takes the report right after the read.
    const heldRead = () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            const send = (event: object) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
            timer = setInterval(() => controller.enqueue(encoder.encode(": hold-read\n\n")), 50);
            sendRead = () => {
              clearInterval(timer);
              send({ type: "tool-call", toolCallId: "held_read", toolName: "read_file", input: { path: "desktop/src/main.ts" } });
              send({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
              controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              controller.close();
            };
            readHeld();
          },
          cancel() {
            clearInterval(timer);
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
    const steps: StoryStep[] = [
      { at: 0, calls: [{ name: "subagent", input: { action: "message", agent: "reviewer", message: `${CHILD_MARKER} Review the createWindow change.` } }] },
      { at: 1, response: heldRead },
      { at: 2, text: "The reviewer is done." },
    ];
    const root = createStoryRoot();
    roots.push(root);
    // The reviewer answers once main's read is open, so its report cannot
    // come before the read.
    const gateway = startStoryGateway(steps, () => readStarted.then(() => "Reviewed."));
    gateways.push(gateway);
    const tracePath = join(root.root, "trace.log");
    const trace = () => existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    const env = { ...storyEnv(root, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "worker" };
    const session = await TmuxSession.create({ cwd: root.workspace, env, width: 110, height: 60 });
    sessions.push(session);
    await session.waitForComposer();
    await session.sendText("ask the reviewer");
    await session.waitForPane(() => /event=mail_posted .*mail=report delivery=joined/.test(trace()), TIMEOUT);
    sendRead!();
    await session.waitForText("The reviewer is done.", TIMEOUT);

    const expectOwnLine = (lines: string[]) => {
      // Main's calls share a group; the report is a line of its own after
      // it, not a row of that group.
      const calls = treeRows(group(lines, /^● /));
      expect(calls).toEqual(["├ Messaged reviewer", "└ Read main.ts"]);
      expect(lines.filter((line) => /^● reviewer finished\b/.test(line))).toHaveLength(1);
      expect(lines.some((line) => /^(├|└) reviewer finished\b/.test(line))).toBe(false);
    };
    expectOwnLine(paneLines(await session.waitForComposer(TIMEOUT)));

    await session.kill();
    sessions.splice(sessions.indexOf(session), 1);
    const resumed = await TmuxSession.create({
      cmd: `${FX_BIN} --resume last`,
      cwd: root.workspace,
      env: storyEnv(root, gateway),
      width: 110,
      height: 60,
    });
    sessions.push(resumed);
    await resumed.waitForText("The reviewer is done.", TIMEOUT);
    expectOwnLine(paneLines(await resumed.waitForComposer(TIMEOUT)));
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "the collapsed view keeps one line per group",
  async () => {
    const { pane } = await runStory(FAILING_BUILD, {
      prompt: "the desktop build is broken, can you fix it?",
      finalText: "Fixed the build.",
      settings: { collapse_tool_calls: true },
    });
    const lines = paneLines(pane);
    expect(lines).toContain("● ran commands ✗");
    // With no rows to show them, the header keeps the edit's counts.
    expect(lines).toContain("● edited a file +1 -1, ran a command, read a file, and more ✓");
    expect(lines.filter((line) => line.startsWith("├ ") || line.startsWith("└ "))).toEqual([]);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "repeated calls share one row, and Ctrl+O still shows every call",
  async () => {
    const { session, pane } = await runStory(REPEATS, {
      prompt: "do the desktop tests pass?",
      finalText: "The tests pass on the third run.",
      height: 100,
    });
    const lines = paneLines(pane);
    expect(lines).toContain("● ran sh test.sh ×3 · passed on the 3rd run ✓");
    expect(lines).toContain("● read main.ts · 3 parts");
    expect(lines.filter((line) => line.includes("sh test.sh"))).toHaveLength(1);

    await session.sendKeys("C-o");
    const full = await session.waitForText("esc close", TIMEOUT);
    expect(full.split("sh test.sh").length - 1).toBeGreaterThanOrEqual(3);
    expect(full.split("read desktop/src/main.ts").length - 1).toBeGreaterThanOrEqual(3);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "one pattern searched in two folders shares a row that names them",
  async () => {
    const { session, pane } = await runStory(SEARCHES, {
      prompt: "who calls createWindow?",
      finalText: "Two files use createWindow.",
    });
    const lines = paneLines(pane);
    // The row names both folders the pattern was searched in.
    expect(treeRows(group(lines, "● searched"))).toEqual([
      "├ searched createWindow in src, desktop",
      "└ matched *.ts",
    ]);

    await session.sendKeys("C-o");
    const full = await session.waitForText("esc close", TIMEOUT);
    expect(full.split("searched createWindow").length - 1).toBeGreaterThanOrEqual(2);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "reads and searches share a row each, and the header says what the group did",
  async () => {
    const { session, pane } = await runStory(EXPLORE, {
      prompt: "how is the main window made?",
      finalText: "createWindow builds the main window.",
    });
    const lines = paneLines(pane);
    // Each file and pattern shows once, though other calls came between
    // them, where it was last read or searched, so window.ts, read again
    // after main.ts, comes last. The header names the kinds of work with no
    // counts.
    expect(treeRows(group(lines, "● read files, searched, ran a command ✓"))).toEqual([
      "├ read main.ts, window.ts",
      "├ searched createWindow, BrowserWindow",
      "└ ran sh check.sh status",
    ]);

    // Ctrl+O still shows each call.
    await session.sendKeys("C-o");
    const full = await session.waitForText("esc close", TIMEOUT);
    expect(full.split("desktop/src/window.ts").length - 1).toBeGreaterThanOrEqual(2);
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "subagent calls do not repeat",
  async () => {
    const { pane } = await runStory(SUBAGENTS, {
      prompt: "review the createWindow change with two subagents",
      finalText: "Both subagents finished.",
      childReply: (task) => task.includes("Review") ? "No bugs found." : "24 tests passed.",
    });
    const lines = paneLines(pane);
    // The two waits share one row; the status keeps its own.
    const rows = treeRows(group(lines, "● started subagents"));
    expect(rows).toHaveLength(4);
    // Each row names the action and the subagent, with no message; Ctrl+O
    // shows the message.
    expect(rows[0]).toBe("├ messaged reviewer");
    expect(rows[1]).toBe("├ messaged tester");
    expect(lines.join("\n")).not.toContain("Review the createWindow change");
    expect(rows.filter((row) => row.includes("Waited for"))).toHaveLength(1);
    expect(rows[3]).toContain("Checked");
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "a narrow terminal and hostile command output stay on one line",
  async () => {
    const width = 64;
    const { pane } = await runStory(HOSTILE, {
      prompt: "run the script",
      finalText: "The script failed.",
      width,
    });
    const lines = paneLines(pane);
    // The failed call is its group's line, and the error's line follows it
    // there, clipped to the width.
    const row = lines.find((line) => /^● .*sh hostile\.sh · /.test(line));
    expect(row).toBeDefined();
    // The reason is the error's message alone, without its "error:".
    expect(row!).toContain(" · xxxx");
    expect(row!).not.toContain("error:");
    expect(row!).toEndWith("…");
    expect([...row!].length).toBeLessThanOrEqual(width);
    expect(lines.some((line) => line.startsWith("  ✗ "))).toBe(false);
    expect(lines.some((line) => line.includes("starting"))).toBe(false);
  },
  TIMEOUT * 2,
);
