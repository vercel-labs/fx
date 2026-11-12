// The compact transcript tells what each group of tool calls did and how it
// ended: a header that names the group's main event, one row for calls that
// repeat one task, a reason line under a failed call, and a recap on the turn
// summary.
import { afterEach, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { FX_BIN } from "../evals/eval-helpers";
import {
  CHILD_MARKER,
  createStoryRoot,
  sh,
  startStoryGateway,
  type StoryRoot,
  type StoryStep,
} from "./fixtures/story-model";
import { FAKE_GATEWAY_MODEL, TmuxSession, tmuxAvailable } from "./tmux-helpers";

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

function storyEnv(root: StoryRoot, gateway: ReturnType<typeof startStoryGateway>) {
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
    childReply?: (task: string) => string;
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

    const checks = group(lines, "● Ran 3 shell commands ✗");
    // The two passing checks share a row by their step; the failure keeps
    // its own.
    expect(treeRows(checks)).toEqual([
      "├ Ran sh check.sh",
      expect.stringMatching(/^└ .*sh build\.sh$/),
    ]);
    expect(checks).toContain("  ✗ exit 2 · src/main.ts:14:15 - error TS2554: Expected 1 arguments, but got 3.");

    const fix = group(lines, "● Edited desktop/src/main.ts +1 -1 ✓");
    const fixRows = treeRows(fix);
    expect(fixRows).toHaveLength(4);
    expect(fixRows[0]).toStartWith("├ Searched");
    // A read shows the file by name.
    expect(fixRows[1]).toBe("├ Read window.ts");
    expect(fixRows[2]).toBe("├ Edited desktop/src/main.ts +1 / -1");
    expect(fixRows[3]).toBe("└ Ran sh build.sh");
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
    expect(group(resumedLines, "● Ran 3 shell commands ✗")).toEqual(checks);
    expect(group(resumedLines, "● Edited desktop/src/main.ts +1 -1 ✓")).toEqual(fix);
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
    expect(lines).toContain("● Ran 3 shell commands ✗");
    expect(lines).toContain("● Edited desktop/src/main.ts +1 -1 ✓");
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
    expect(lines).toContain("● Ran sh test.sh ×3 · passed on the 3rd run ✓");
    expect(lines).toContain("● Read main.ts · 3 parts");
    expect(lines.filter((line) => line.includes("sh test.sh"))).toHaveLength(1);

    await session.sendKeys("C-o");
    const full = await session.waitForText("esc close", TIMEOUT);
    expect(full.split("sh test.sh").length - 1).toBeGreaterThanOrEqual(3);
    expect(full.split("Read desktop/src/main.ts").length - 1).toBeGreaterThanOrEqual(3);
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
    // The header counts patterns, not calls.
    expect(treeRows(group(lines, "● Searched for 2 patterns"))).toEqual([
      "├ Searched createWindow in src, desktop",
      "└ Matched *.ts",
    ]);

    await session.sendKeys("C-o");
    const full = await session.waitForText("esc close", TIMEOUT);
    expect(full.split("Searched createWindow").length - 1).toBeGreaterThanOrEqual(2);
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
    const rows = treeRows(group(lines, "● Started 2 subagents"));
    expect(rows).toHaveLength(4);
    expect(rows[0]).toContain("reviewer");
    expect(rows[1]).toContain("tester");
    expect(rows.filter((row) => row.includes("waited for"))).toHaveLength(1);
    expect(rows[3]).toContain("checked");
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
    const block = group(lines, /^● .*sh hostile\.sh$/);
    const reason = block.find((line) => line.startsWith("  ✗ "));
    expect(reason).toBeDefined();
    expect(reason!).toStartWith("  ✗ exit 3 · error: xxxx");
    expect(reason!).toEndWith("…");
    expect([...reason!].length).toBeLessThanOrEqual(width);
    expect(lines.some((line) => line.includes("starting"))).toBe(false);
  },
  TIMEOUT * 2,
);
