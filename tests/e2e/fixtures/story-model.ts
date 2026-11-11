// A scripted model for transcript story tests. Each reply is chosen by how
// many tool results the request already carries, so the script does not
// depend on how many requests fx makes between steps. A subagent child's
// first request is answered from its task instead.
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fakeGatewaySse, startDynamicFakeGateway } from "../tmux-helpers";

export type StoryCall = { name: string; input: Record<string, unknown> };

export type StoryStep = {
  /** The number of tool results the request carries when this step answers. */
  at: number;
  text?: string;
  calls?: StoryCall[];
};

export const CHILD_MARKER = "[story-child]";

let callCounter = 0;

export function storyReply(step: { text?: string; calls?: StoryCall[] }): Response {
  const events: object[] = [];
  if (step.text) events.push({ type: "text-delta", id: "story_text", delta: step.text });
  for (const call of step.calls ?? []) {
    callCounter += 1;
    events.push({
      type: "tool-call",
      toolCallId: `story_call_${callCounter}`,
      toolName: call.name,
      input: call.input,
    });
  }
  events.push((step.calls?.length ?? 0) > 0
    ? { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } }
    : {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
    });
  return fakeGatewaySse(events);
}

type RequestShape = { toolResults: number; childTask?: string };

function requestShape(body: string): RequestShape {
  let toolResults = 0;
  let assistant = false;
  const userTexts: string[] = [];
  const walk = (value: unknown, role?: string) => {
    if (Array.isArray(value)) {
      for (const item of value) walk(item, role);
      return;
    }
    if (!value || typeof value !== "object") {
      if (typeof value === "string" && role === "user") userTexts.push(value);
      return;
    }
    const record = value as Record<string, unknown>;
    const ownRole = typeof record.role === "string" ? record.role : role;
    if (record.role === "assistant") assistant = true;
    if (record.type === "tool-result") toolResults += 1;
    for (const child of Object.values(record)) walk(child, ownRole);
  };
  walk(JSON.parse(body));
  const childTask = assistant ? undefined : userTexts.find((text) => text.includes(CHILD_MARKER));
  return { toolResults, childTask };
}

export function startStoryGateway(steps: StoryStep[], childReply?: (task: string) => string) {
  return startDynamicFakeGateway((body) => {
    const shape = requestShape(body);
    if (shape.childTask !== undefined && childReply) {
      return storyReply({ text: childReply(shape.childTask) });
    }
    const step = steps.find((candidate) => candidate.at === shape.toolResults);
    if (!step) {
      return new Response(`no scripted step after ${shape.toolResults} tool results`, { status: 500 });
    }
    return storyReply(step);
  });
}

export const sh = (command: string): StoryCall => ({ name: "shell", input: { action: "run", command } });

export const MAIN_TS = [
  "import { createWindow } from \"./window\";",
  "import { createTray } from \"./tray\";",
  "",
  "const url = process.env.APP_URL ?? \"http://localhost:5173\";",
  "",
  "export function start() {",
  "  const tray = createTray();",
  "  tray.on(\"quit\", () => process.exit(0));",
  "",
  "  if (process.env.HEADLESS === \"1\") {",
  "    return null;",
  "  }",
  "",
  "  const win = createWindow(url, 1280, 800);",
  "  return win;",
  "}",
  "",
].join("\n");

const WINDOW_TS = [
  "export interface WindowOptions {",
  "  url: string;",
  "  width: number;",
  "  height: number;",
  "}",
  "",
  "export function createWindow(options: WindowOptions) {",
  "  return { ...options };",
  "}",
  "",
].join("\n");

// sh build.sh fails while start() still passes three arguments.
const BUILD_SH = `if grep -q 'createWindow(url, 1280, 800)' desktop/src/main.ts; then
  echo "> desktop@0.9.2 build"
  echo
  echo "src/main.ts:14:15 - error TS2554: Expected 1 arguments, but got 3."
  echo
  echo "14   const win = createWindow(url, 1280, 800);"
  echo
  echo "Found 1 error in src/main.ts:14"
  exit 2
fi
echo "> desktop@0.9.2 build"
echo "built in 1.84s"
`;

// sh test.sh fails twice, then passes.
const TEST_SH = `n=$(cat .story-flaky 2>/dev/null || echo 0)
if [ "$n" -lt 2 ]; then
  echo $((n + 1)) > .story-flaky
  echo " FAIL  src/tray.test.ts > tray > quits on click"
  echo "Error: Test timed out in 5000ms."
  echo "      Tests  1 failed | 23 passed (24)"
  exit 1
fi
echo "      Tests  24 passed (24)"
`;

// sh hostile.sh writes escape sequences, carriage returns, tabs, a long
// error line, and invalid UTF-8, then fails.
const HOSTILE_SH = `printf '\\033[31mstarting\\033[0m\\r\\tstep\\n'
printf 'error: %s \\377\\376 end\\n' "$(printf 'x%.0s' $(seq 1 500))"
exit 3
`;

const CHECK_SH = `case "$1" in
  status) echo "## main...origin/main"; echo "109de9e Add APP_URL override" ;;
  remote) printf '0\\t0\\n' ;;
esac
`;

export type StoryRoot = { root: string; home: string; workspace: string };

export function createStoryRoot(settings: Record<string, unknown> = {}): StoryRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tool-story-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(join(workspace, "desktop", "src"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", ...settings }));
  writeFileSync(join(workspace, "desktop", "src", "main.ts"), MAIN_TS);
  writeFileSync(join(workspace, "desktop", "src", "window.ts"), WINDOW_TS);
  for (const [name, body] of Object.entries({
    "build.sh": BUILD_SH,
    "test.sh": TEST_SH,
    "hostile.sh": HOSTILE_SH,
    "check.sh": CHECK_SH,
  })) {
    writeFileSync(join(workspace, name), body);
    chmodSync(join(workspace, name), 0o755);
  }
  return { root, home, workspace: realpathSync(workspace) };
}
