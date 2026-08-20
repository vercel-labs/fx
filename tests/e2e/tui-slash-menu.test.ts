import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync, execSync } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  isComposerLine,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const TEST_TIMEOUT = 120_000;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";
const DIM_SGR = "\x1b[38;5;245m";

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
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

function isSlashCommandRow(line: string): boolean {
  const visible = line
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .trimStart();
  return visible.startsWith("/");
}

function selectedSlashRowIndex(escapes: string): number {
  const rows = escapes.split("\n").filter(isSlashCommandRow);
  return rows.findIndex((line) => line.includes(SELECTED_COMPLETION_SGR));
}

test("slash menu selection index ignores the welcome header help hint", () => {
  const header = `${SELECTED_COMPLETION_SGR}𝒇x\x1b[0m${DIM_SGR} v0.3.27 · Run /help for commands`;
  const unselected = "\x1b[38;5;245m/help show available slash commands";
  const selected = `${SELECTED_COMPLETION_SGR}  /clear\x1b[38;5;245m start a fresh session and keep background processes`;

  expect(selectedSlashRowIndex(`${header}\n${unselected}\n${selected}`)).toBe(1);
});

function capturePaneHistory(session: TmuxSession, start = -120): string {
  return execSync(`tmux capture-pane -t ${session.name} -p -S ${start}`, {
    stdio: "pipe",
    encoding: "utf-8",
  });
}

function captureViewportEscapes(session: TmuxSession): string {
  return execFileSync("tmux", ["capture-pane", "-t", session.name, "-e", "-p"], {
    stdio: "pipe",
    encoding: "utf-8",
  });
}

async function waitForPaneTitle(
  session: TmuxSession,
  expected: string,
  timeout: number,
): Promise<void> {
  const deadline = Date.now() + timeout;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.paneTitle();
    if (latest === expected) return;
    await Bun.sleep(50);
  }
  throw new Error(`pane title never became ${expected}; last saw ${latest}`);
}

async function waitForSkillsMenu(session: TmuxSession, count: number): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    if (latest.join("\n").includes(`Skills ${count}`)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for skills menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForModelsMenu(session: TmuxSession, count: number): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    if (latest.join("\n").includes(`Models ${count}`)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for models menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForHelpMenu(session: TmuxSession, count: number): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    if (latest.join("\n").includes(`Commands ${count}`)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for help menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForSettingsMenu(session: TmuxSession): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (pane.includes("Settings") && pane.includes("←→ Change")) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for settings menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForSettingValue(
  settingsPath: string,
  key: string,
  expected: unknown,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  let latest: unknown;
  while (Date.now() < deadline) {
    if (existsSync(settingsPath)) {
      latest = JSON.parse(readFileSync(settingsPath, "utf8"))[key];
      if (Object.is(latest, expected)) return;
    }
    await Bun.sleep(100);
  }
  throw new Error(
    `Timed out waiting for ${key}=${JSON.stringify(expected)}; last=${JSON.stringify(latest)}`,
  );
}

async function waitForAppearanceMenu(
  session: TmuxSession,
  expectedSelection?: string,
): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (
      pane.includes("Input appearance") &&
      pane.includes("Maxxing mode") &&
      (expectedSelection === undefined || pane.includes(expectedSelection))
    ) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for appearance menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForStatuslineMenu(
  session: TmuxSession,
  expectedSelection?: string,
): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (
      pane.includes("Status line") &&
      !pane.includes("↑↓ Navigate") &&
      !pane.includes("←→ Change") &&
      (expectedSelection === undefined || pane.includes(expectedSelection))
    ) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for status line menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForSandboxMenu(session: TmuxSession): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (pane.includes("Sandbox") && pane.includes("←→ Change")) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for sandbox menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForUsageMenu(session: TmuxSession): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (pane.includes("Usage · 30 days") && pane.includes("Esc Close")) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for usage menu.\nPane:\n${latest.join("\n")}`);
}

async function waitForWorkspaceMenu(session: TmuxSession): Promise<string[]> {
  const deadline = Date.now() + TIMEOUT;
  let latest: string[] = [];
  while (Date.now() < deadline) {
    latest = await session.capturePaneGrid();
    const pane = latest.join("\n");
    if (pane.includes("Workspace:") && pane.includes("Enter Use")) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for workspace menu.\nPane:\n${latest.join("\n")}`);
}

type HeldSkillStream = {
  cancelled: boolean;
  release?: () => void;
};

function heldSkillStreamResponse(state: HeldSkillStream): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  const event = (value: object) =>
    encoder.encode(`data: ${JSON.stringify(value)}\n\n`);

  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(event({ type: "text-start", id: "answer_1" }));
        controller.enqueue(event({
          type: "text-delta",
          id: "answer_1",
          delta: "catalog stream active",
        }));
        timer = setInterval(() => {
          if (!closed) controller.enqueue(encoder.encode(": hold-skill-stream\n\n"));
        }, 50);
        state.release = () => {
          if (closed) return;
          closed = true;
          if (timer) clearInterval(timer);
          controller.enqueue(event({
            type: "text-delta",
            id: "answer_1",
            delta: " catalog stream completed",
          }));
          controller.enqueue(event({ type: "text-end", id: "answer_1" }));
          controller.enqueue(event({
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
          }));
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        };
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function waitForHeldSkillStream(state: HeldSkillStream): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (state.release) return;
    await Bun.sleep(25);
  }
  throw new Error("Timed out waiting for the held skill stream.");
}

function leadingBlankLineCount(text: string): number {
  let count = 0;
  for (const line of text.split("\n")) {
    if (line.trim().length > 0) return count;
    count += 1;
  }
  return count;
}

function nestedText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(nestedText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [nestedText(value.text), nestedText(value.value), nestedText(value.content)].join("");
  }
  return "";
}

function gatewayPromptText(body: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  return request.prompt.map((message) => nestedText(message.content)).join("\n");
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function fileMarkerCount(path: string, marker: string): number {
  if (!existsSync(path)) return 0;
  return countOccurrences(readFileSync(path, "utf8"), marker);
}

function createSkillsMenuFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-skills-menu-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx", "skills", "managed-menu"), { recursive: true });
  mkdirSync(join(home, ".codex", "skills", "codex-menu"), { recursive: true });
  mkdirSync(join(home, ".agents", "skills", "compat-menu"), { recursive: true });
  mkdirSync(join(workspace, "skills", "workspace-menu"), { recursive: true });
  writeFileSync(
    join(home, ".fx", "skills", "managed-menu", "SKILL.md"),
    "---\nname: managed-menu\ndescription: |\n  managed menu first line\n  managed menu second line\n---\n\nManaged body\n",
  );
  writeFileSync(
    join(workspace, "skills", "workspace-menu", "SKILL.md"),
    "---\nname: workspace-menu\ndescription: workspace menu skill\n---\n\nWorkspace body\n",
  );
  writeFileSync(
    join(home, ".codex", "skills", "codex-menu", "SKILL.md"),
    "---\nname: codex-menu\ndescription: codex menu skill\n---\n\nCodex body\n",
  );
  writeFileSync(
    join(home, ".agents", "skills", "compat-menu", "SKILL.md"),
    "---\nname: compat-menu\ndescription: compatibility menu skill\n---\n\nCompatibility body\n",
  );
  writeFileSync(stderrPath, "");
  return { home, workspace, stderrPath };
}

function createSkillRankingFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-skill-rank-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx", "skills", "workflow-helper"), { recursive: true });
  mkdirSync(join(home, ".codex", "skills", "zig-best-practices"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "skills", "workflow-helper", "SKILL.md"),
    "---\nname: workflow-helper\ndescription: simplify Zig workflows\n---\n\nWorkflow body\n",
  );
  writeFileSync(
    join(home, ".codex", "skills", "zig-best-practices", "SKILL.md"),
    "---\nname: zig-best-practices\ndescription: write robust Zig\n---\n\nZig body\n",
  );
  writeFileSync(stderrPath, "");
  return { home, workspace, stderrPath };
}

function createLinkedSkillsMenuFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-linked-skills-menu-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const source = join(workspace, "skill-source", "linked-menu");
  const skillsRoot = join(workspace, ".codex", "skills");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(source, { recursive: true });
  mkdirSync(skillsRoot, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}\n");
  writeFileSync(
    join(source, "SKILL.md"),
    "---\nname: linked-menu\ndescription: linked menu skill\n---\n\nLINKED_MENU_BODY\n",
  );
  symlinkSync(
    "../../skill-source/linked-menu",
    join(skillsRoot, "linked-menu"),
    "dir",
  );
  writeFileSync(stderrPath, "");
  return { home, workspace, stderrPath };
}

function createModelsMenuFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-models-menu-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const settingsPath = join(home, ".fx", "settings.json");
  const tapePath = join(root, "models-menu.fxtape");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(settingsPath, "{}\n");
  writeFileSync(stderrPath, "");
  return { home, workspace, settingsPath, tapePath, stderrPath };
}

// The menu matcher searches skill paths, so this fixture's home directory must
// not contain the substring "home": a "home" path segment would make the
// query HOME match every installed skill.
function createMentionGuardFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mention-guard-")));
  workDirs.push(root);
  const home = join(root, "hq");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx", "skills", "managed-menu"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "skills", "managed-menu", "SKILL.md"),
    "---\nname: managed-menu\ndescription: managed menu skill\n---\n\nManaged body\n",
  );
  if (home.toLowerCase().includes("home")) {
    throw new Error(`mention-guard fixture path leaks 'home': ${home}`);
  }
  return { home, workspace };
}

function createExactSkillsMenuFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-exact-skills-menu-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const managed = join(home, ".fx", "skills", "exact-picker-managed");
  const workspaceSkill = join(workspace, "skills", "exact-picker-workspace");
  const malformed = join(home, ".agents", "skills", "malformed-picker");
  const bodyA = "EXACT_PICKER_MANAGED_BODY";
  const bodyB = "EXACT_PICKER_WORKSPACE_BODY";
  const workspaceDescription = "workspace duplicate picker";

  mkdirSync(managed, { recursive: true });
  mkdirSync(workspaceSkill, { recursive: true });
  mkdirSync(malformed, { recursive: true });
  writeFileSync(
    join(managed, "SKILL.md"),
    `---\nname: exact-picker\ndescription: managed duplicate picker\n---\n\n${bodyA}\n`,
  );
  writeFileSync(
    join(workspaceSkill, "SKILL.md"),
    `---\nname: exact-picker\ndescription: ${workspaceDescription}\n---\n\n${bodyB}\n`,
  );
  writeFileSync(
    join(malformed, "SKILL.md"),
    "---\nname: malformed-picker\nname: duplicate-picker\n---\n\nMALFORMED_PICKER_BODY\n",
  );

  return {
    root,
    home,
    workspace,
    bodyA,
    bodyB,
    workspaceDescription,
    malformedMarker: "malformed-picker",
  };
}

function createManySkillsMenuFixture(count: number) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-skills-menu-many-")));
  workDirs.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  for (let i = 0; i < count; i += 1) {
    const name = `skill-${String(i).padStart(3, "0")}`;
    mkdirSync(join(home, ".fx", "skills", name), { recursive: true });
    writeFileSync(
      join(home, ".fx", "skills", name, "SKILL.md"),
      `---\nname: ${name}\ndescription: generated skill ${i}\n---\n\nGenerated body\n`,
    );
  }
  mkdirSync(workspace, { recursive: true });
  return { home, workspace, stderrPath };
}

function visibleFxSkillNames(grid: string[]): string[] {
  return grid
    .filter((line) => line.includes("skill-") && line.includes("Fx · Global"))
    .map((line) => line.match(/skill-\d+/)?.[0])
    .filter((name): name is string => name !== undefined);
}

function selectedSkillName(escapes: string): string | null {
  const row = escapes
    .split("\n")
    .find((line) => line.includes(SELECTED_COMPLETION_SGR) && line.includes("skill-"));
  return row?.match(/skill-\d+/)?.[0] ?? null;
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

function submittedSkillRows(escapes: string): string[] {
  return escapes.split("\n").filter((line) =>
    /(?:┃|❯) managed-menu please/.test(stripAnsi(line))
  );
}

function gridFromAnsiCapture(capture: string): string[] {
  return capture.replace(/\n$/, "").split("\n").map(stripAnsi);
}

function lastRowMatching(grid: string[], predicate: (line: string) => boolean): number {
  for (let index = grid.length - 1; index >= 0; index -= 1) {
    if (predicate(grid[index] ?? "")) return index + 1;
  }
  throw new Error(`row not found in grid:\n${grid.join("\n")}`);
}

function composerRow(grid: string[]): number {
  return lastRowMatching(grid, isComposerLine);
}

function footerStatusRow(grid: string[]): number {
  return lastRowMatching(
    grid,
    (line) => line.includes("gpt-5") || line.includes("↑↓ Navigate"),
  );
}

function visibleTranscriptTailRow(grid: string[]): number {
  return lastRowMatching(grid, (line) => line.includes("SLASH_FOOTER_E2E_"));
}

function assertNoBlankGapBetweenTranscriptAndComposer(grid: string[]) {
  const transcriptTail = visibleTranscriptTailRow(grid);
  const composer = composerRow(grid);
  let consecutiveBlankRows = 0;
  for (let row = transcriptTail + 1; row < composer; row += 1) {
    if ((grid[row - 1] ?? "").trim() === "") {
      consecutiveBlankRows += 1;
      expect(consecutiveBlankRows, `blank block above composer reaches row ${row}`).toBeLessThanOrEqual(2);
    } else {
      consecutiveBlankRows = 0;
    }
  }
}

function longAssistantResponse(): string {
  return Array.from({ length: 82 }, (_, index) => {
    const line = String(index + 1).padStart(3, "0");
    return `SLASH_FOOTER_E2E_${line} markdown transcript content that should fill the viewport above the composer.`;
  }).join("\n");
}

describe.skipIf(SKIP)("tui: slash menu", () => {
  test(
    "linked workspace skill is visible and usable from the skills menu",
    async () => {
      const fixture = createLinkedSkillsMenuFixture();
      gateway = startFakeGateway([
        fakeGatewayFinalText("LINKED_MENU_COMPLETE"),
      ]);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-linked-menu-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
        stderrPath: fixture.stderrPath,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/skills");
      const menu = await waitForSkillsMenu(session, 1);
      expect(menu.join("\n")).toContain("linked-menu");
      expect(menu.join("\n")).toContain("Codex · Workspace");
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => composerContains(pane, "linked-menu"),
        5_000,
      );
      await session.sendLiteralText(" apply it");
      await session.sendKeys("Enter");
      await session.waitForText("LINKED_MENU_COMPLETE", 10_000);

      expect(gateway.requests).toHaveLength(1);
      expect(gatewayPromptText(gateway.requests[0]!.body)).toContain(
        "LINKED_MENU_BODY",
      );
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "skill picker selects a name match before a metadata-only match",
    async () => {
      const fixture = createSkillRankingFixture();
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
        stderrPath: fixture.stderrPath,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("$zig");
      const grid = await waitForSkillsMenu(session, 2);
      const directIndex = grid.findIndex((line) => line.includes("zig-best-practices"));
      const metadataIndex = grid.findIndex((line) => line.includes("workflow-helper"));
      expect(directIndex).toBeGreaterThanOrEqual(0);
      expect(metadataIndex).toBeGreaterThan(directIndex);

      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => composerContains(pane, "zig-best-practices"),
        5_000,
      );
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "terminal tab title follows the session name across rename and resume",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-title-rename-e2e-"));
      workDirs.push(workDir);
      const home = join(workDir, "home");
      const workspace = join(workDir, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission: {} }),
      );

      const stderrPath = join(workDir, "stderr.log");
      const resumedStderrPath = join(workDir, "resumed-stderr.log");
      const model = "openai/gpt-5";
      gateway = startFakeGateway([fakeGatewayFinalText("TITLE_RENAME_COMPLETE")]);

      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-title-rename-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: model,
        FX_AUTO_UPGRADE: "0",
        NO_COLOR: "1",
      };

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        env,
        stderrPath,
        width: 120,
        height: 32,
        isolated: true,
      });
      await session.waitForComposer(10_000);

      // Before the first turn names the session, the workspace distinguishes
      // parallel tabs while the model remains visible.
      expect(await session.paneTitle()).toBe(`fx · workspace · ${model}`);

      // The first prompt names the session, and the tab follows it.
      await session.sendText("generate the release notes");
      await session.waitForText("TITLE_RENAME_COMPLETE", 30_000);
      await waitForPaneTitle(session, `fx · generate the release notes · ${model}`, 5_000);

      await session.sendText("/rename deploy pipeline fix");
      await session.waitForText("renamed: deploy pipeline fix", 10_000);
      await waitForPaneTitle(session, `fx · deploy pipeline fix · ${model}`, 5_000);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      await session.kill();
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const sessionIds = readdirSync(join(home, ".fx", "sessions"), {
        withFileTypes: true,
      })
        .filter((entry) => entry.name !== "latest" && entry.isDirectory())
        .map((entry) => entry.name);
      expect(sessionIds).toHaveLength(1);

      // Resuming restores both the chosen name and active model context.
      gateway.stop();
      gateway = startFakeGateway([]);
      session = await TmuxSession.create({
        cmd: `${FX_BIN} resume ${sessionIds[0]}`,
        cwd: workspace,
        env: {
          ...env,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        stderrPath: resumedStderrPath,
        width: 120,
        height: 32,
        isolated: true,
      });
      await session.waitForComposer(10_000);
      await waitForPaneTitle(session, `fx · deploy pipeline fix · ${model}`, 5_000);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      await session.kill();
      session = null;
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
    },
    TEST_TIMEOUT,
  );

  test(
    "slash picker growth preserves displaced transcript history",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-slash-footer-e2e-"));
      workDirs.push(workDir);
      const home = join(workDir, "home");
      const workspace = join(workDir, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));

      const tracePath = join(workDir, "trace.log");
      const tapePath = join(workDir, "resumed.fxtape");
      const stderrPath = join(workDir, "stderr.log");
      const resumedStderrPath = join(workDir, "resumed-stderr.log");
      gateway = startFakeGateway([fakeGatewayFinalText(longAssistantResponse())]);

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-slash-footer-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: "openai/gpt-5",
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        stderrPath,
        width: 124,
        height: 75,
        isolated: true,
        minimumHistoryLines: 500,
      });
      await session.waitForComposer(10_000);
      await session.sendText("Print the deterministic slash footer transcript fixture.");
      await session.waitForText("SLASH_FOOTER_E2E_082", 30_000);
      await session.waitForPane(
        (pane) => !pane.includes("esc interrupt") && !pane.includes("Thinking"),
        5_000,
      );
      await Bun.sleep(300);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      await session.kill();
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const sessionIds = readdirSync(join(home, ".fx", "sessions"), {
        withFileTypes: true,
      })
        .filter((entry) => entry.name !== "latest" && entry.isDirectory())
        .map((entry) => entry.name);
      expect(sessionIds).toHaveLength(1);
      gateway.stop();
      gateway = startFakeGateway([]);
      session = await TmuxSession.create({
        cmd: `${FX_BIN} resume ${sessionIds[0]}`,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-slash-footer-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: "openai/gpt-5",
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "frame_plan,frame_layout,scroll,render,paint,frame_diff,frame_commit",
          NO_COLOR: "1",
        },
        stderrPath: resumedStderrPath,
        width: 124,
        height: 75,
        isolated: true,
        minimumHistoryLines: 500,
      });
      await session.waitForComposer(10_000);
      await session.waitForText("SLASH_FOOTER_E2E_082", 30_000);

      async function capture(label: string): Promise<string[]> {
        const deadline = Date.now() + 5_000;
        let previous = "";
        let viewportAnsi = "";
        let stableSamples = 0;
        while (Date.now() < deadline && stableSamples < 5) {
          viewportAnsi = await session!.capturePaneEscapes();
          if (viewportAnsi === previous) {
            stableSamples += 1;
          } else {
            previous = viewportAnsi;
            stableSamples = 0;
          }
          await Bun.sleep(50);
        }
        if (stableSamples < 5) {
          throw new Error(`Timed out waiting for a stable viewport before ${label}`);
        }
        const fullAnsi = await session!.captureFullScrollbackEscapes();
        writeFileSync(join(workDir, `${label}.ansi.txt`), fullAnsi);
        writeFileSync(join(workDir, `${label}.pane.ansi.txt`), viewportAnsi);
        writeFileSync(join(workDir, `${label}.pane.txt`), stripAnsi(viewportAnsi));
        return gridFromAnsiCapture(viewportAnsi);
      }

      const afterResponse = await capture("after-response");
      const closedComposerRow = composerRow(afterResponse);
      expect(
        visibleTranscriptTailRow(afterResponse),
        `resumed baseline grid:\n${afterResponse.join("\n")}`,
      ).toBe(71);
      expect(closedComposerRow).toBe(73);
      await session.sendLiteralText("/");
      await session.waitForText("Commands 39", 5_000);
      const afterSlash = await capture("after-slash");
      expect(visibleTranscriptTailRow(afterSlash)).toBe(62);
      expect(composerRow(afterSlash)).toBe(64);
      await session.sendLiteralText("f");
      await session.waitForText("/feedback", 5_000);
      const afterSlashF = await capture("after-slash-f");
      await session.sendLiteralText("e");
      await session.waitForText("/feedback", 5_000);
      const afterSlashFe = await capture("after-slash-fe");
      await session.sendLiteralText("edback");
      await session.waitForText("/feedback", 5_000);
      const afterSlashFeedback = await capture("after-slash-feedback");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) =>
          composerContains(pane, "/feedback") &&
          !pane.includes("open the fx feedback form"),
        5_000,
      );
      const afterDismiss = await capture("after-dismiss");
      expect(visibleTranscriptTailRow(afterDismiss)).toBe(62);
      expect(composerRow(afterDismiss)).toBe(64);
      expect(footerStatusRow(afterDismiss)).toBe(66);
      await session.sendLiteralText("x");
      await session.waitForPane(
        (pane) =>
          composerContains(pane, "/feedbackx") &&
          !pane.includes("open the fx feedback form"),
        5_000,
      );
      const afterDismissEdit = await capture("after-dismiss-edit");
      expect(visibleTranscriptTailRow(afterDismissEdit)).toBe(62);
      expect(composerRow(afterDismissEdit)).toBe(64);
      expect(footerStatusRow(afterDismissEdit)).toBe(66);

      await session.sendKeys("C-u");
      await session.waitForPane(hasEmptyComposer, 5_000);
      const afterClear = await capture("after-clear");

      const openComposerRows = [
        composerRow(afterSlash),
        composerRow(afterSlashF),
        composerRow(afterSlashFe),
        composerRow(afterSlashFeedback),
      ];
      const openFooterRows = [
        footerStatusRow(afterSlash),
        footerStatusRow(afterSlashF),
        footerStatusRow(afterSlashFe),
        footerStatusRow(afterSlashFeedback),
      ];
      expect(new Set(openComposerRows).size).toBe(1);
      expect(new Set(openFooterRows).size).toBe(1);
      expect(openComposerRows[0]).toBeLessThan(composerRow(afterResponse));
      expect(composerRow(afterDismiss)).toBeLessThan(closedComposerRow);
      expect(composerRow(afterDismissEdit)).toBe(composerRow(afterDismiss));
      expect(composerRow(afterClear)).toBe(composerRow(afterDismiss));
      expect(footerStatusRow(afterDismiss)).toBeLessThan(footerStatusRow(afterResponse));
      expect(footerStatusRow(afterDismissEdit)).toBe(footerStatusRow(afterDismiss));
      expect(footerStatusRow(afterClear)).toBe(footerStatusRow(afterDismiss));

      for (const grid of [
        afterResponse,
        afterSlash,
        afterSlashF,
        afterSlashFe,
        afterSlashFeedback,
        afterDismiss,
        afterDismissEdit,
        afterClear,
      ]) {
        assertNoBlankGapBetweenTranscriptAndComposer(grid);
      }

      const historyLabels = [
        "after-response",
        "after-slash",
        "after-slash-f",
        "after-slash-fe",
        "after-slash-feedback",
        "after-dismiss",
        "after-dismiss-edit",
        "after-clear",
      ];
      const baselineScrollback = stripAnsi(
        readFileSync(join(workDir, "after-response.ansi.txt"), "utf8"),
      );
      const expectedMarkerCopies = Array.from({ length: 82 }, (_, index) => {
        const marker = `SLASH_FOOTER_E2E_${String(index + 1).padStart(3, "0")}`;
        const copies = countOccurrences(baselineScrollback, marker);
        expect(copies, `after-response: ${marker}`).toBeGreaterThanOrEqual(1);
        expect(copies, `after-response: ${marker}`).toBeLessThanOrEqual(2);
        return { marker, copies };
      });
      for (const label of historyLabels.slice(1)) {
        const scrollback = stripAnsi(readFileSync(join(workDir, `${label}.ansi.txt`), "utf8"));
        for (const { marker, copies } of expectedMarkerCopies) {
          expect(countOccurrences(scrollback, marker), `${label}: ${marker}`).toBe(copies);
        }
      }

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      session = null;

      const trace = readFileSync(tracePath, "utf8");
      const traceLines = trace.split(/\r?\n/);
      const footerUpdates = traceLines.filter((line) => line.includes("footer_extra_update"));
      expect(footerUpdates.some((line) => /old=0 new=9 .*picker_rows=8 show_picker=true/.test(line))).toBe(true);
      expect(footerUpdates.some((line) => /old=9 new=0 .*picker_rows=0 show_picker=false/.test(line))).toBe(true);
      expect(footerUpdates.some((line) => /show_picker=true/.test(line) && /new=[1-8](?:\s|$)/.test(line))).toBe(false);
      const openUpdateIndex = traceLines.findIndex((line) => /footer_extra_update old=0 new=9 /.test(line));
      expect(openUpdateIndex).toBeGreaterThanOrEqual(0);
      const openPlan = traceLines.slice(0, openUpdateIndex).reverse().find((line) =>
        line.includes("transcript_transition_plan") &&
        line.includes("replay_displaced_footer_history=true") &&
        /planned_rows=[1-9][0-9]*/.test(line)
      );
      expect(openPlan).toContain("source_compatible=true");
      const openCommit = traceLines.slice(openUpdateIndex + 1).find((line) =>
        line.includes("[frame_diff] attempt_result") &&
        /planned_scroll_rows=[1-9][0-9]*/.test(line)
      );
      expect(openCommit).toMatch(
        /planned_scroll_rows=([1-9][0-9]*) committed_scroll_rows=\1 .*unplanned_scroll_rows=0/,
      );
      const closeUpdateIndex = traceLines.findIndex((line) => /footer_extra_update old=9 new=0 /.test(line));
      expect(closeUpdateIndex).toBeGreaterThanOrEqual(0);
      const closePlan = traceLines.slice(openUpdateIndex + 1, closeUpdateIndex).reverse().find((line) =>
        line.includes("transcript_transition_plan") &&
        line.includes("replay_displaced_footer_history=false")
      );
      expect(closePlan).toContain("planned_rows=0");
      const closeFrame = traceLines.slice(closeUpdateIndex + 1).find((line) => line.includes("[frame_diff] result"));
      expect(closeFrame).toMatch(/full_repaint=true invalidation=external_clear/);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");

      const replayOutput = execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
        encoding: "utf8",
      });
      writeFileSync(join(workDir, "replay.json"), replayOutput);
      const replay = JSON.parse(replayOutput);
      expect(replay.frame_count).toBeGreaterThan(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);
    },
    90_000,
  );

  test(
    "slash menu renders its header described rows categories and controls",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-slash-main-menu-e2e-"));
      workDirs.push(workDir);
      const home = join(workDir, "home");
      const workspace = join(workDir, "workspace");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendKeys("-l '/m'");
      await session.waitForPane(
        (pane) => pane.includes("Commands ") && pane.includes("/model"),
        5_000,
      );

      const initialGrid = await session.capturePaneGrid();
      const modelRow = initialGrid.find((line) =>
        line.includes("/model") && line.includes("choose what model and reasoning effort to use")
      );
      const modelsRow = initialGrid.find((line) =>
        line.includes("/models") && line.includes("browse available models")
      );
      expect(modelRow).toBeDefined();
      expect(modelsRow).toBeDefined();
      expect(modelRow!.trimStart().startsWith("/model")).toBe(true);
      expect(modelRow!.indexOf("choose")).toBe(modelsRow!.indexOf("browse"));
      const metadataColumn = modelRow!.lastIndexOf("Model");
      expect(modelsRow!.lastIndexOf("Model")).toBe(metadataColumn);

      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.waitForText("manage MCP servers, resources, and prompts", 5_000);
      const scrolledGrid = await session.capturePaneGrid();
      const mcpRow = scrolledGrid.find((line) =>
        line.includes("/mcp") && line.includes("manage MCP servers, resources, and prompts")
      );
      expect(mcpRow).toBeDefined();
      expect(mcpRow!.indexOf("Extensions")).toBe(metadataColumn);
      expect(mcpRow!.indexOf("Extensions") + "Extensions".length).toBe(99);
      expect(modelRow).toContain("Model");
      expect(scrolledGrid.join("\n")).toContain("↑↓ Navigate     Enter Use     Esc Close");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "settings can hide slash menu metadata and persist the choice",
    async () => {
      const { home, workspace } = createSkillsMenuFixture();
      const settingsPath = join(home, ".fx", "settings.json");

      const launch = () =>
        TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
          },
          width: 100,
          height: 30,
        });

      session = await launch();
      await session.waitForComposer(10_000);
      await session.sendText("/settings");
      let grid = await waitForSettingsMenu(session);
      expect(grid.join("\n")).toContain("Slash menu categories");

      for (let index = 0; index < 5; index += 1) {
        await session.sendKeys("Down");
      }
      await session.sendKeys("Left");
      await waitForSettingValue(settingsPath, "slash_menu_categories", false);
      grid = await waitForSettingsMenu(session);
      expect(grid.join("\n")).toContain("Slash menu categories");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) => hasEmptyComposer(pane) && !pane.includes("←→ Change"),
        5_000,
      );
      await session.sendLiteralText("/m");
      await session.waitForPane(
        (pane) => pane.includes("Results ") && pane.includes("/model"),
        5_000,
      );
      grid = await session.capturePaneGrid();
      const modelRow = grid.find((line) => line.includes("/model"));
      const mcpRow = grid.find((line) => line.includes("/mcp"));
      expect(modelRow).toContain("choose what model and reasoning effort to use");
      expect(modelRow).not.toContain("Model");
      expect(mcpRow).toContain("manage MCP servers, resources, and prompts");
      expect(mcpRow).not.toContain("Extensions");

      await session.sendKeys("C-u");
      await session.sendLiteralText("/managed-menu");
      await session.waitForText("managed menu first line", 5_000);
      grid = await session.capturePaneGrid();
      const skillRow = grid.find((line) => line.includes("managed menu first line"));
      expect(skillRow).toContain("managed-menu");
      expect(skillRow).not.toContain("global .fx");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;

      session = await launch();
      await session.waitForComposer(10_000);
      await session.sendLiteralText("/m");
      await session.waitForPane(
        (pane) => pane.includes("Results ") && pane.includes("/model"),
        5_000,
      );
      grid = await session.capturePaneGrid();
      const restartedModelRow = grid.find((line) => line.includes("/model"));
      const restartedMcpRow = grid.find((line) => line.includes("/mcp"));
      expect(restartedModelRow).toBeDefined();
      expect(restartedMcpRow).toBeDefined();
      expect(restartedModelRow).not.toContain("Model");
      expect(restartedMcpRow).not.toContain("Extensions");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "Escape closes slash picker until the slash trigger restarts",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-slash-escape-e2e-"));
      workDirs.push(workDir);
      const home = join(workDir, "home");
      const workspace = join(workDir, "workspace");
      const stderrPath = join(workDir, "stderr.log");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        stderrPath,
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      const description = "choose what model and reasoning effort to use";
      await session.sendLiteralText("/mo");
      await session.waitForText(description, 5_000);

      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) => composerContains(pane, "/mo") && !pane.includes(description),
        5_000,
      );

      await session.sendLiteralText("d");
      await session.waitForPane(
        (pane) => composerContains(pane, "/mod") && !pane.includes(description),
        5_000,
      );

      await session.sendKeys("C-u");
      await session.sendLiteralText("/mo");
      await session.waitForText(description, 5_000);
      await session.sendKeys("C-[");
      await session.waitForPane(
        (pane) => composerContains(pane, "/mo") && !pane.includes(description),
        5_000,
      );

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TEST_TIMEOUT,
  );

  test(
    "slash query lifecycle keeps eligibility projection and submission aligned",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-slash-lifecycle-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const skillDir = join(home, ".fx", "skills", "resume-helper");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(skillDir, { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(skillDir, "SKILL.md"),
        "---\nname: resume-helper\ndescription: resume a named saved workflow\n---\n\nResume helper body\n",
      );

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        stderrPath,
        width: 88,
        height: 24,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("/he");
      await session.waitForText("/help", 5_000);
      await session.sendLiteralText("zzzzz");
      let pane = await session.waitForText("no matching slash commands", 5_000);
      expect(composerContains(pane, "/hezzzzz")).toBe(true);
      expect(pane).not.toContain("Enter Use");
      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) =>
          composerContains(current, "/hezzzzz") &&
          !current.includes("no matching slash commands"),
        5_000,
      );

      await session.sendKeys("C-u");
      await session.sendLiteralText("/name");
      pane = await session.waitForPane(
        (current) => current.includes("/rename") && current.includes("resume-helper"),
        5_000,
      );
      expect(pane.indexOf("/rename")).toBeLessThan(pane.indexOf("resume-helper"));

      await session.sendKeys("C-u");
      await session.pasteText("\n   ");
      await session.sendLiteralText("/");
      await session.waitForText("/help", 5_000);
      await session.sendLiteralText("help");
      await session.sendKeys("Enter");
      pane = await session.waitForText("Commands", 5_000);
      expect(pane).toContain("show available slash commands");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && current.includes("𝒇x") && !current.includes("Commands"),
        5_000,
      );
      await session.sendLiteralText("/resume ");
      pane = await session.waitForPane(
        (current) =>
          composerContains(current, "/resume") &&
          !current.includes("resume-helper") &&
          !current.includes("Enter Use"),
        5_000,
      );
      expect(pane).not.toContain("no matching slash commands");
      await session.sendKeys("Enter");
      await session.waitForText("Sessions 0", 5_000);

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && current.includes("𝒇x") && !current.includes("Sessions"),
        5_000,
      );
      await session.sendLiteralText("/sandbox ");
      pane = await session.waitForPane(
        (current) => current.includes("os") && current.includes("none"),
        5_000,
      );
      expect(pane).not.toContain("resume-helper");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.pasteText("\n   ");
      await session.sendLiteralText("/resume-helper");
      await session.waitForText("Enter Use", 5_000);
      await session.sendKeys("Enter");
      pane = await session.waitForPane(
        (current) =>
          current.includes("resume-helper") &&
          !current.includes("Enter Use") &&
          !current.includes("Fx needs access to Vercel AI Gateway"),
        5_000,
      );
      expect(composerContains(pane, "resume-helper")).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TEST_TIMEOUT,
  );

  test(
    "help command filters the catalog and opens selected commands",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-help-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/help");
      let grid = await waitForHelpMenu(session, 39);
      let pane = grid.join("\n");
      expect(pane).not.toContain("𝒇x");
      expect(pane).not.toContain("Run /help for commands");
      expect(pane).toContain("General");
      expect(pane).toContain("/help");
      expect(pane).not.toContain("● /help");
      expect(pane).toContain("show available slash commands");
      expect(pane).toContain("↑↓ Navigate");
      expect(pane).toContain("Enter Open");

      await session.sendLiteralText("clipboard");
      grid = await waitForHelpMenu(session, 1);
      pane = grid.join("\n");
      expect(composerContains(pane, "clipboard")).toBe(true);
      expect(pane).toContain("Media");
      expect(pane).toContain("/paste");
      expect(pane).not.toContain("/clear");

      await session.sendKeys("C-u");
      await waitForHelpMenu(session, 39);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      pane = await session.waitForPane(
        (current) => hasEmptyComposer(current) && !current.includes("Commands 39"),
        5_000,
      );
      expect(composerContains(pane, "/clear")).toBe(false);
      expect(capturePaneHistory(session, -1000)).not.toContain("● Help:");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/help");
      await waitForHelpMenu(session, 39);
      await session.sendLiteralText("additional directories");
      await waitForHelpMenu(session, 1);
      await session.sendKeys("Enter");
      pane = await session.waitForPane(
        (current) =>
          composerContains(current, "/workspace") &&
          current.includes("list") &&
          current.includes("add") &&
          current.includes("𝒇x"),
        5_000,
      );
      expect(pane).not.toContain("Commands 1");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/help");
      await waitForHelpMenu(session, 39);
      await session.sendLiteralText("no command can match this query");
      await session.waitForText("No commands found.", 5_000);
      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && current.includes("𝒇x") && !current.includes("Enter Open"),
        5_000,
      );

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "settings command opens the inline list and saves selected values",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-settings-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const settingsPath = join(home, ".fx", "settings.json");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(settingsPath, `${JSON.stringify({ input_appearance: "tint" })}\n`);

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/settings");
      const grid = await waitForSettingsMenu(session);
      let pane = grid.join("\n");
      expect(pane).not.toContain("𝒇x");
      expect(pane).not.toContain("Run /help for commands");
      expect(pane).toContain("Settings");
      expect(pane).toContain("Interface");
      expect(pane).toContain("Agent");
      expect(pane).toContain("Notifications");
      expect(pane).toContain("Advanced");
      expect(pane).toContain("↑↓ Navigate");
      expect(pane).toContain("←→ Change");
      expect(pane).toContain("Esc Close");
      expect(pane).not.toContain("[All]");
      expect(pane).not.toContain("Enter Change");

      expect(pane).toContain("Input appearance");
      await session.sendKeys("Left");
      await waitForSettingValue(settingsPath, "input_appearance", "lines");

      await session.sendKeys("Down");
      await session.waitForText(/Maxxing mode\s+minimal/, 5_000);
      await session.sendKeys("Left");
      await waitForSettingValue(settingsPath, "maxxing_mode", "legacy");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) =>
          hasEmptyComposer(current) &&
          current.includes("𝒇x") &&
          !current.includes("←→ Change"),
        5_000,
      );
      expect(capturePaneHistory(session, -1000)).not.toContain("● Settings:");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "appearance command applies both independent settings from one inline panel",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-appearance-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const settingsPath = join(home, ".fx", "settings.json");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        settingsPath,
        `${JSON.stringify({
          input_appearance: "tint",
          maxxing_mode: "minimal",
        })}\n`,
      );

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/appearance");
      let grid = await waitForAppearanceMenu(session);
      let pane = grid.join("\n");
      expect(pane).toContain("𝒇x");
      expect(pane).toContain("Input appearance");
      expect(pane).toContain("Maxxing mode");
      expect(pane).toContain("lines  tint");
      expect(pane).toContain("minimal  legacy");
      expect(pane).not.toContain("❯");
      expect(pane).not.toContain("✓");
      expect(pane).toContain("Tab Section");
      expect(pane).toContain("←→ Change");

      await session.sendKeys("Right");
      await waitForSettingValue(settingsPath, "input_appearance", "lines");
      grid = await waitForAppearanceMenu(session, "lines  tint");
      pane = grid.join("\n");
      expect(pane).not.toContain("✓");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).input_appearance).toBe("lines");

      await session.sendKeys("Tab");
      await session.waitForText("minimal  legacy", 5_000);
      await session.sendKeys("Right");
      await waitForSettingValue(settingsPath, "maxxing_mode", "legacy");
      grid = await waitForAppearanceMenu(session, "minimal  legacy");
      pane = grid.join("\n");
      expect(pane).not.toContain("✓");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).maxxing_mode).toBe("legacy");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) =>
          hasEmptyComposer(current) &&
          current.includes("𝒇x") &&
          !current.includes("Appearance · Choose one"),
        5_000,
      );
      expect(session.isAlive()).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "compact catalogs keep their actionable rows visible",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-compact-catalogs-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const settingsPath = join(home, ".fx", "settings.json");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(settingsPath, `${JSON.stringify({ input_appearance: "tint" })}\n`);

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 60,
        height: 6,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/help");
      let pane = await session.waitForText("Commands 39", 5_000);
      expect(pane).toContain("/help");
      expect(pane).not.toContain("● /help");
      await session.sendKeys("Escape");

      await session.resizeWindow(60, 7, 500);
      await session.sendText("/settings");
      pane = (await waitForSettingsMenu(session)).join("\n");
      expect(pane).toContain("Input appearance");

      await session.resizeWindow(60, 9, 500);
      await session.sendKeys("Left");
      await waitForSettingValue(settingsPath, "input_appearance", "lines");
      pane = (await waitForSettingsMenu(session)).join("\n");
      expect(pane).toContain("Input appearance");
      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && !current.includes("←→ Change"),
        5_000,
      );

      await session.resizeWindow(60, 12, 500);
      await session.sendText("/appearance");
      pane = await session.waitForText("Appearance", 5_000);
      expect(pane).toContain("Input appearance");
      expect(pane).toContain("lines  tint");
      expect(pane).toContain("Maxxing mode");
      expect(pane).toContain("minimal  legacy");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && !current.includes("←→ Change"),
        5_000,
      );
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "statusline command toggles independent items from a compact inline panel",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-statusline-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const settingsPath = join(home, ".fx", "settings.json");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        settingsPath,
        `${JSON.stringify({
          statusLine: { sandbox: false, context: false },
        })}\n`,
      );

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/statusline");
      let grid = await waitForStatuslineMenu(session);
      let pane = grid.join("\n");
      expect(pane).toContain("Sandbox");
      expect(pane).toContain("Context");
      expect(pane).toContain("off  on");
      expect(pane).not.toContain("❯");
      expect(pane).not.toContain("Choose what appears");
      expect(pane).not.toContain("↑↓ Navigate");
      expect(pane).not.toContain("←→ Change");

      await session.sendKeys("Right");
      grid = await waitForStatuslineMenu(session, "off  on");
      pane = grid.join("\n");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).statusLine.sandbox).toBe(true);

      await session.sendKeys("Down");
      await session.sendKeys("Right");
      grid = await waitForStatuslineMenu(session, "Context");
      pane = grid.join("\n");
      expect(pane).not.toContain("saved to user settings");
      expect(pane).not.toContain("● Statusline:");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).statusLine.context).toBe(true);

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) =>
          hasEmptyComposer(current) &&
          current.includes("𝒇x") &&
          !current.includes("←→ Change"),
        5_000,
      );
      expect(session.isAlive()).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "sandbox command applies a mode from a compact inline panel",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-sandbox-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const settingsPath = join(home, ".fx", "settings.json");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(settingsPath, `${JSON.stringify({ sandbox: "none" })}\n`);

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/sandbox");
      let grid = await waitForSandboxMenu(session);
      let pane = grid.join("\n");
      expect(pane).toContain("Command sandbox");
      expect(pane).toContain("Choose command process isolation");
      expect(pane).toContain("os  none");
      expect(pane).not.toContain("✓");
      expect(pane).not.toContain("❯");
      expect(pane).not.toContain("Choose one");
      expect(pane).toContain("←→ Change");

      await session.sendKeys("Down");
      await session.sendKeys("Right");
      grid = await waitForSandboxMenu(session);
      pane = grid.join("\n");
      expect(pane).toContain("Command sandbox");
      expect(pane).toContain("os  none");
      expect(pane).not.toContain("✓");
      expect(pane).not.toContain("❯");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).sandbox).toBe("none");

      await session.sendKeys("Escape");
      await session.waitForPane(
        (current) =>
          hasEmptyComposer(current) &&
          current.includes("𝒇x") &&
          !current.includes("←→ Change"),
        5_000,
      );
      expect(session.isAlive()).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage and cost commands open one compact inline dashboard",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cost-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/cost");
      let grid = await waitForUsageMenu(session);
      let pane = grid.join("\n");
      expect(pane).toContain("Tracking has not started");
      expect(pane).not.toMatch(/^● Usage/m);

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/usage");
      grid = await waitForUsageMenu(session);
      pane = grid.join("\n");
      expect(pane).toContain("Usage · 30 days");

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage dashboard preserves ledger totals when recovery storage is unsafe",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-recovery-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      const now = Date.now();
      writeFileSync(
        join(fxDir, "usage.jsonl"),
        JSON.stringify({
          schema_version: 1,
          kind: "coverage",
          started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
        }) + "\n",
        { mode: 0o600 },
      );
      writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });
      const outside = join(root, "outside");
      writeFileSync(outside, "not a session directory");
      symlinkSync(outside, join(fxDir, "sessions"));

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);
      await session.sendText("/usage");
      const pane = (await waitForUsageMenu(session)).join("\n");
      expect(pane).not.toContain("Usage unavailable");
      expect(pane).toContain("Known totals may be incomplete.");
      expect(pane).toMatch(/Total tokens +0/);

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage dashboard refresh discovers usage created after startup",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-late-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home, { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);
      await session.sendText("/usage");
      await session.waitForText("Tracking has not started", TIMEOUT);

      const fxDir = join(home, ".fx");
      const now = Date.now();
      writeFileSync(
        join(fxDir, "usage.jsonl"),
        [
          JSON.stringify({
            schema_version: 1,
            kind: "coverage",
            started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
          }),
          JSON.stringify({
            schema_version: 1,
            kind: "generation",
            fact: {
              id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              created_at_ms: now - 1_000,
              model: "provider/a",
              input_tokens: 10,
              output_tokens: 2,
              cache_read_tokens: 1,
              cache_write_tokens: 0,
              reasoning_tokens: 1,
              total_cost: 0.25,
            },
          }),
        ].join("\n") + "\n",
        { mode: 0o600 },
      );
      writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });

      await session.sendLiteral("R");
      const pane = await session.waitForText(/Total tokens +12/, TIMEOUT);
      expect(pane).toContain("provider/a");

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage dashboard retry recovers after profile initialization becomes safe",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-retry-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home, { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      const unsafeTarget = join(root, "unsafe-profile");
      mkdirSync(unsafeTarget, { mode: 0o700 });
      symlinkSync(unsafeTarget, join(home, ".fx"));

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);
      await session.sendText("/usage");
      await session.waitForText(
        "Usage unavailable · press R to retry",
        TIMEOUT,
      );

      rmSync(join(home, ".fx"));
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { mode: 0o700 });
      const now = Date.now();
      writeFileSync(
        join(fxDir, "usage.jsonl"),
        [
          JSON.stringify({
            schema_version: 1,
            kind: "coverage",
            started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
          }),
          JSON.stringify({
            schema_version: 1,
            kind: "generation",
            fact: {
              id: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              created_at_ms: now - 1_000,
              model: "provider/a",
              input_tokens: 10,
              output_tokens: 2,
              cache_read_tokens: 1,
              cache_write_tokens: 0,
              reasoning_tokens: 1,
              total_cost: 0.25,
            },
          }),
        ].join("\n") + "\n",
        { mode: 0o600 },
      );
      writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });

      await session.sendLiteral("R");
      const pane = await session.waitForText(/Total tokens +12/, TIMEOUT);
      expect(pane).not.toContain("Usage unavailable");

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage dashboard reaches Session when every rolling scope is unavailable",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-corrupt-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(fxDir, "usage.jsonl"), "{\"broken\":true}\n", {
        mode: 0o600,
      });
      writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);
      await session.sendText("/usage");
      let pane = await session.waitForText(
        "Usage unavailable · press R to retry",
        TIMEOUT,
      );
      expect(pane).toContain("Usage · 30 days");

      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · 7 days", TIMEOUT);
      expect(pane).toContain("Usage unavailable · press R to retry");
      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · 24 hours", TIMEOUT);
      expect(pane).toContain("Usage unavailable · press R to retry");
      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · Session", TIMEOUT);
      expect(pane).toMatch(/Total tokens +0/);
      expect(pane).toContain("Session activity");

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "usage dashboard changes scope, selects and expands models, and refreshes",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      const now = Date.now();
      const fact = (
        id: string,
        model: string,
        createdAtMs: number,
        input: number,
        output: number,
        cost: number,
      ) => ({
        schema_version: 1,
        kind: "generation",
        fact: {
          id,
          created_at_ms: createdAtMs,
          model,
          input_tokens: input,
          output_tokens: output,
          cache_read_tokens: 1,
          cache_write_tokens: 0,
          reasoning_tokens: 1,
          total_cost: cost,
        },
      });
      const usagePath = join(fxDir, "usage.jsonl");
      writeFileSync(
        usagePath,
        [
          JSON.stringify({
            schema_version: 1,
            kind: "coverage",
            started_at_ms: now - 40 * 24 * 60 * 60 * 1000,
          }),
          JSON.stringify(
            fact(
              "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "provider/a",
              now - 60 * 60 * 1000,
              100,
              20,
              1,
            ),
          ),
          JSON.stringify(
            fact(
              "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
              "provider/b",
              now - 2 * 24 * 60 * 60 * 1000,
              10,
              2,
              0.1,
            ),
          ),
          JSON.stringify(
            fact(
              "gen_01ARZ3NDEKTSV4RRFFQ69G5FAX",
              "provider/c",
              now - 10 * 24 * 60 * 60 * 1000,
              4,
              1,
              0.01,
            ),
          ),
        ].join("\n") + "\n",
        { mode: 0o600 },
      );
      writeFileSync(join(fxDir, "usage.lock"), "", { mode: 0o600 });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 36,
      });
      await session.waitForComposer(10_000);
      await session.sendText("/usage");
      let pane = await session.waitForText(/Total tokens +137/, TIMEOUT);
      expect(pane).toContain("Usage · 30 days");

      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · 7 days", TIMEOUT);
      expect(pane).toMatch(/Total tokens +132/);
      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · 24 hours", TIMEOUT);
      expect(pane).toMatch(/Total tokens +120/);
      await session.sendKeys("Left");
      pane = await session.waitForText("Usage · Session", TIMEOUT);
      expect(pane).toMatch(/Total tokens +0/);
      expect(pane).toContain("Session activity");
      await session.sendKeys("Right");
      await session.waitForText("Usage · 24 hours", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText("Usage · 7 days", TIMEOUT);

      await session.sendKeys("Down");
      pane = await session.waitForText(/❯ provider\/b/, TIMEOUT);
      await session.sendKeys("Enter");
      pane = await session.waitForText(/In 10 · Out 2/, TIMEOUT);
      expect(pane).toContain("Requests 1");
      await session.resizeWindow(72, 16);
      pane = await session.waitForText(/In 10 · Out 2/, TIMEOUT);
      expect(pane).toMatch(/❯ provider\/b/);
      await session.resizeWindow(120, 36);
      pane = await session.waitForText(/In 10 · Out 2/, TIMEOUT);
      expect(pane).toMatch(/❯ provider\/b/);

      appendFileSync(
        usagePath,
        JSON.stringify(
          fact(
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FAY",
            "provider/d",
            now - 500,
            4,
            1,
            0.01,
          ),
        ) + "\n",
      );
      await session.sendLiteral("R");
      pane = await session.waitForText(/Total tokens +137/, TIMEOUT);
      expect(pane).toMatch(/❯ provider\/b/);

      appendFileSync(usagePath, "{\"broken\":true}\n");
      await session.sendLiteral("R");
      pane = await session.waitForText(
        "Refresh failed · showing the previous snapshot",
        TIMEOUT,
      );
      expect(pane).toMatch(/Total tokens +137/);

      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "workspace command opens a compact inline manager and prepares existing commands",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-workspace-menu-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const shared = join(root, "shared");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      mkdirSync(shared, { recursive: true });
      const workspaceRoot = realpathSync(workspace);
      const sharedRoot = realpathSync(shared);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({
          workspaces: {
            [workspaceRoot]: {
              additional_directories: [sharedRoot],
            },
          },
        })}\n`,
      );

      session = await TmuxSession.create({
        cwd: workspaceRoot,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/workspace");
      let grid = await waitForWorkspaceMenu(session);
      let pane = grid.join("\n");
      expect(pane).toContain("❯ Add directory…");
      expect(
        grid.some((line) => line.includes("Primary") && line.includes("/")),
      ).toBe(true);
      expect(
        grid.some((line) =>
          line.includes("/") && line.includes("Active · Saved")
        ),
      ).toBe(true);
      expect(pane).toMatch(/Additional directories\s+1 \/ 16/);

      await session.sendKeys("Enter");
      await session.waitForPane(
        (current) =>
          composerContains(current, "/workspace add") &&
          !current.includes("Enter Use"),
        5_000,
      );

      await session.sendKeys("C-u");
      await session.sendText("/workspace");
      await waitForWorkspaceMenu(session);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      pane = await session.waitForPane(
        (current) =>
          composerContains(current, `/workspace remove ${sharedRoot}`) &&
          !current.includes("Enter Use"),
        5_000,
      );
      expect(composerContains(pane, `/workspace remove ${sharedRoot}`)).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "inline completions stay in the composer while leading triggers open their menus",
    async () => {
      const fixture = createSkillsMenuFixture();
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
        stderrPath: fixture.stderrPath,
      });
      await session.waitForComposer(10_000);

      await session.sendKeys("-l '/sk'");
      await session.waitForText("browse and manage skills", 5_000);
      let grid = await session.capturePaneGrid();
      expect(grid.join("\n")).toContain("𝒇x");
      expect(grid.join("\n")).not.toContain("Skills 4");
      await session.sendKeys("Enter");
      grid = await waitForSkillsMenu(session, 4);
      const pane = grid.join("\n");
      expect(pane).not.toContain("𝒇x");
      expect(pane).not.toContain("Run /help for commands");
      expect(pane).toContain("[All]");
      expect(pane).toContain("Fx");
      expect(pane).toContain("Workspace");
      expect(pane).toContain("Claude");
      expect(pane).toContain("Codex");
      expect(pane).toContain("Agents");
      expect(pane).toContain("managed-menu");
      expect(pane).toContain("Fx · Global");
      expect(pane).toContain("workspace-menu");
      expect(pane).toContain("Fx · Workspace");
      expect(pane).toContain("↑↓ Navigate");
      expect(pane).toContain("Enter Use");

      const deep_history = capturePaneHistory(session, -1000);
      const tail_history = capturePaneHistory(session, -80);
      expect(deep_history).not.toContain("Visible skills (");
      expect(deep_history).not.toContain("skill discovery warning:");
      expect(leadingBlankLineCount(tail_history)).toBeLessThan(3);
      expect(tail_history).not.toContain("𝒇x v0.3.7");
      const escapes = await session.capturePaneEscapes();
      expect(escapes).not.toContain(`${DIM_SGR}fx-review`);
      expect(deep_history).not.toMatch(/(?:┃|❯) \/sk/);

      await session.sendLiteralText("work");
      grid = await waitForSkillsMenu(session, 1);
      expect(composerContains(grid.join("\n"), "work")).toBe(true);
      expect(grid.join("\n")).toContain("workspace-menu");
      expect(grid.join("\n")).not.toContain("managed menu second line");

      await session.sendKeys("C-[");
      await session.waitForPane(
        (current) =>
          hasEmptyComposer(current) &&
          current.includes("𝒇x") &&
          !current.includes("↑↓ Navigate"),
        5_000,
      );

      await session.sendLiteralText("$work");
      grid = await waitForSkillsMenu(session, 1);
      expect(composerContains(grid.join("\n"), "$work")).toBe(true);
      expect(grid.join("\n")).not.toContain("𝒇x");
      await session.sendKeys("C-[");
      await session.waitForPane(
        (current) =>
          composerContains(current, "$work") &&
          current.includes("𝒇x") &&
          !current.includes("↑↓ Navigate"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText(" $");
      await session.waitForPane(
        (current) =>
          composerContains(current, " $") &&
          current.includes("𝒇x") &&
          !current.includes("Skills 4"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText("hello $");
      await session.waitForPane(
        (current) =>
          composerContains(current, "hello $") &&
          current.includes("𝒇x") &&
          !current.includes("Skills 4"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain $man");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain $managed-menu") &&
          !current.includes("Skills 4"),
        5_000,
      );
      let inlineEscapes = await session.capturePaneEscapes();
      expect(inlineEscapes).toContain(`${DIM_SGR}aged-menu`);

      await session.sendKeys("C-[");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain $man") &&
          !current.includes("aged-menu"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain $man");
      await session.waitForPane(
        (current) => composerContains(current, "explain $managed-menu"),
        5_000,
      );
      await session.sendKeys("Tab");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain managed-menu") &&
          !current.includes("Skills 4"),
        5_000,
      );
      inlineEscapes = await session.capturePaneEscapes();
      expect(inlineEscapes).toContain(`${SELECTED_COMPLETION_SGR}managed-menu`);
      expect(inlineEscapes).not.toContain(`${DIM_SGR}aged-menu`);
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain $man");
      await session.waitForPane(
        (current) => composerContains(current, "explain $managed-menu"),
        5_000,
      );
      await session.sendKeys("Right");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain managed-menu") &&
          !current.includes("Skills 4"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain /sk");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain /skills") &&
          !current.includes("browse and manage skills") &&
          !current.includes("Skills 4"),
        5_000,
      );
      inlineEscapes = await session.capturePaneEscapes();
      expect(inlineEscapes).toContain(`${DIM_SGR}ills`);

      await session.sendKeys("C-[");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain /sk") &&
          !current.includes("explain /skills"),
        5_000,
      );
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain /sk");
      await session.waitForPane(
        (current) => composerContains(current, "explain /skills"),
        5_000,
      );
      await session.sendKeys("Tab");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain /skills") &&
          !current.includes("browse and manage skills") &&
          !current.includes("Skills 4"),
        5_000,
      );
      inlineEscapes = await session.capturePaneEscapes();
      expect(inlineEscapes).not.toContain(`${DIM_SGR}ills`);
      await session.sendKeys("C-u");

      await session.sendLiteralText("explain /he");
      await session.waitForPane(
        (current) => composerContains(current, "explain /help"),
        5_000,
      );
      await session.sendKeys("Right");
      await session.waitForPane(
        (current) =>
          composerContains(current, "explain /help") &&
          !current.includes("show available slash commands"),
        5_000,
      );
      inlineEscapes = await session.capturePaneEscapes();
      expect(inlineEscapes).not.toContain(`${DIM_SGR}lp`);
      await session.sendKeys("C-u");

      await session.sendText("/skills");
      await waitForSkillsMenu(session, 4);
      await session.sendKeys("Tab");
      await session.waitForText("[Fx]", 5_000);
      await session.sendKeys("BTab");
      await session.waitForText("[All]", 5_000);
      await session.sendLiteralText("workspace");
      await waitForSkillsMenu(session, 1);
      await session.sendKeys("Enter");
      grid = await session.capturePaneGrid();
      expect(composerContains(grid.join("\n"), "workspace-menu")).toBe(true);
      expect(grid.join("\n")).toContain("𝒇x");
      expect(grid.join("\n")).not.toContain("↑↓ Navigate");
      expect(capturePaneHistory(session, -1000)).not.toContain("Unknown command");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/skills");
      await waitForSkillsMenu(session, 4);
      await session.sendKeys("Tab");
      await session.sendKeys("Tab");
      await session.sendKeys("Tab");
      await session.sendKeys("Tab");
      grid = await session.capturePaneGrid();
      const codexPane = grid.join("\n");
      expect(codexPane).toContain("[Codex]");
      expect(codexPane).toContain("codex-menu");
      expect(codexPane).toContain("Codex · Global");

      await session.sendKeys("C-[");
      await session.waitForPane((current) => !current.includes("↑↓ Navigate"), 5_000);
      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "large skills list moves through visible rows before scrolling",
    async () => {
      const fixture = createManySkillsMenuFixture(220);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath: fixture.stderrPath,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 28,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("$");
      let grid = await waitForSkillsMenu(session, 220);
      const initialNames = visibleFxSkillNames(grid);
      expect(initialNames.length).toBeGreaterThan(4);

      for (let i = 0; i < initialNames.length - 1; i += 1) {
        await session.sendKeys("Down");
      }

      grid = await session.capturePaneGrid();
      expect(visibleFxSkillNames(grid)[0]).toBe(initialNames[0]);
      expect(selectedSkillName(await session.capturePaneEscapes())).toBe(
        initialNames[initialNames.length - 1],
      );

      await session.sendKeys("Down");
      grid = await session.capturePaneGrid();
      expect(visibleFxSkillNames(grid)[0]).toBe(initialNames[1]);

      await session.sendKeys("Up");
      grid = await session.capturePaneGrid();
      expect(visibleFxSkillNames(grid)[0]).toBe(initialNames[1]);
      expect(selectedSkillName(await session.capturePaneEscapes())).toBe(
        initialNames[initialNames.length - 1],
      );
      expect(session.isAlive()).toBe(true);
      expect(capturePaneHistory(session, -1000)).not.toContain("Unknown command");

      await session.sendKeys("C-[");
      await session.waitForPane((current) => !current.includes("↑↓ Navigate"), 5_000);
      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "models command opens a searchable provider catalog and selects through the existing model flow",
    async () => {
      const fixture = createModelsMenuFixture();
      const currentModel = "anthropic/claude-opus-4.8";
      const selectedModel = "private-team/plain-model";
      gateway = startFakeGateway([], {
        models: [
          {
            id: currentModel,
            type: "language",
            released: 400,
            tags: ["reasoning", "tool-use", "vision", "file-input", "web-search"],
            reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
            fast_options: [{ type: "toggle" }],
            context_window: 1_000_000,
            max_tokens: 32_000,
          },
          {
            id: "openai/gpt-5.4",
            type: "language",
            released: 300,
            tags: ["reasoning", "tool-use"],
            context_window: 400_000,
            max_tokens: 64_000,
          },
          {
            id: "google/gemini-3-pro",
            type: "language",
            released: 200,
            tags: ["tool-use", "vision"],
            context_window: 2_000_000,
          },
          {
            id: selectedModel,
            type: "language",
            released: 100,
            tags: ["tool-use"],
            context_window: 128_000,
          },
        ],
      });
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-models-menu-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: currentModel,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: fixture.tapePath,
          FX_RECORD_INPUT: "1",
        },
        width: 120,
        height: 32,
      });
      await session.waitForComposer(10_000);
      expect(await session.paneTitle()).toBe(`fx · workspace · ${currentModel}`);

      await session.sendText("/models");
      let grid = await waitForModelsMenu(session, 4);
      let pane = grid.join("\n");
      expect(pane).not.toContain("𝒇x");
      expect(pane).toContain("[All]");
      expect(pane).toContain(currentModel);
      expect(pane).toContain("1M context · 32K output · Fast");
      expect(pane).not.toContain("Authenticated model catalog loaded.");
      expect(pane).not.toContain("Current");
      expect(pane).not.toContain("Reasoning");
      expect(pane).toContain("↑↓ Navigate");
      expect(pane).toContain("Tab Provider");

      await session.sendKeys("Tab");
      grid = await waitForModelsMenu(session, 1);
      expect(grid.join("\n")).toContain("[Anthropic]");

      await session.sendKeys("BTab");
      await waitForModelsMenu(session, 4);
      await session.sendLiteralText("no-such-model");
      await session.waitForText("No models found.", 5_000);
      await session.sendKeys("C-u");
      await waitForModelsMenu(session, 4);
      await session.sendLiteralText("gemini");
      grid = await waitForModelsMenu(session, 1);
      pane = grid.join("\n");
      expect(composerContains(pane, "gemini")).toBe(true);
      expect(pane).toContain("google/gemini-3-pro");
      expect(pane).not.toContain("openai/gpt-5.4");

      await session.sendKeys("C-[");
      await session.waitForPane(
        (current) => hasEmptyComposer(current) && current.includes("𝒇x") && !current.includes("Tab Provider"),
        5_000,
      );

      await session.sendText("/models");
      await waitForModelsMenu(session, 4);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForPane(
        (current) => composerContains(current, `/model ${currentModel}`) && current.includes("default"),
        5_000,
      );
      expect((JSON.parse(readFileSync(fixture.settingsPath, "utf8")) as { model?: string }).model).toBeUndefined();
      await session.sendKeys("C-u");
      await session.waitForPane(hasEmptyComposer, 5_000);

      await session.sendText("/models");
      await waitForModelsMenu(session, 4);
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText(`● Switched to ${selectedModel}`, 5_000);

      const settings = JSON.parse(readFileSync(fixture.settingsPath, "utf8")) as { model?: string };
      expect(settings.model).toBe(selectedModel);
      expect(await session.paneTitle()).toBe(`fx · workspace · ${selectedModel}`);
      expect(session.isAlive()).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(existsSync(fixture.tapePath)).toBe(true);
      const replay = JSON.parse(
        execFileSync(FX_BIN, ["replay", fixture.tapePath, "--json"], { encoding: "utf8" }),
      ) as { frame_count: number; stdout_bytes: number };
      expect(replay.frame_count).toBeGreaterThan(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);
    },
    TEST_TIMEOUT,
  );

  test(
    "models command keeps shared-prefix ids distinguishable at narrow widths",
    async () => {
      const fixture = createModelsMenuFixture();
      const modelIds = [
        "provider/very-long-shared-family-production-reasoning-alpha",
        "provider/very-long-shared-family-production-reasoning-beta",
        "provider/very-long-shared-family-production-reasoning-gamma",
        "provider/very-long-shared-family-production-reasoning-delta",
      ];
      gateway = startFakeGateway([], {
        models: modelIds.map((id, index) => ({
          id,
          type: "language",
          released: modelIds.length - index,
          tags: ["reasoning"],
          context_window: 128_000,
        })),
      });
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-models-menu-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: modelIds[0],
          FX_AUTO_UPGRADE: "0",
        },
        width: 40,
        height: 24,
        stderrPath: fixture.stderrPath,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/models");
      const pane = (await waitForModelsMenu(session, modelIds.length)).join("\n");
      for (const suffix of ["alpha", "beta", "gamma", "delta"]) {
        expect(pane).toContain(`ing-${suffix}`);
      }
      const rows = pane
        .split("\n")
        .filter((line) => line.includes("ing-"))
        .map((line) => stripAnsi(line).trim());
      expect(new Set(rows).size).toBe(modelIds.length);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    TEST_TIMEOUT,
  );

  test(
    "model picker skips effort stage for reasoning models without declared tiers",
    async () => {
      const fixture = createModelsMenuFixture();
      const selectedModel = "deepseek/deepseek-v4-pro-0813";
      gateway = startFakeGateway([], {
        models: [
          {
            id: selectedModel,
            type: "language",
            released: 100,
            tags: ["reasoning", "tool-use"],
            context_window: 128_000,
          },
        ],
      });
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath: fixture.stderrPath,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-model-picker-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: "openai/gpt-4o",
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("/model ");
      await session.waitForText(selectedModel, 10_000);
      await session.sendLiteralText(selectedModel);
      await session.sendKeys("Enter");
      await session.waitForText(`● Switched to ${selectedModel}`, 5_000);

      const pane = (await session.capturePaneGrid()).join("\n");
      expect(hasEmptyComposer(pane)).toBe(true);
      expect(pane).not.toContain("Reasoning effort");
      expect(pane).not.toContain("default");
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8")).model).toBe(selectedModel);
      expect(await session.paneTitle()).toBe(`fx · workspace · ${selectedModel}`);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "skills catalog retains input ownership for global view shortcuts",
    async () => {
      const fixture = createSkillsMenuFixture();
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
      });
      await session.waitForComposer(10_000);

      await session.sendText("/skills");
      await waitForSkillsMenu(session, 4);
      await session.sendKeys("C-o");
      await session.sendKeys("C-x");

      const grid = await waitForSkillsMenu(session, 4);
      expect(grid.join("\n")).toContain("↑↓ Navigate");
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-[");
      await session.waitForPane((current) => !current.includes("↑↓ Navigate"), 5_000);
      await session.sendText("/skills");
      await waitForSkillsMenu(session, 4);
      await session.sendHexBytes(["1b", "18"]);
      await session.waitForText("Agents & processes", 5_000);
      await session.sendKeys("C-x");
      await session.waitForComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "Escape closes the skills catalog without cancelling an active stream",
    async () => {
      const fixture = createSkillsMenuFixture();
      const stream: HeldSkillStream = { cancelled: false };
      gateway = startFakeGateway([() => heldSkillStreamResponse(stream)]);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-active-skills-stream-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
      });
      await session.waitForComposer(10_000);

      await session.sendText("Keep this response active.");
      await waitForHeldSkillStream(stream);
      await session.waitForText("Thinking", 10_000);
      await session.sendLiteralText("$");
      await waitForSkillsMenu(session, 4);

      await session.sendKeys("C-[");
      await session.waitForPane(
        (pane) => pane.includes("Thinking") && !pane.includes("↑↓ Navigate"),
        5_000,
      );
      expect(stream.cancelled).toBe(false);

      stream.release?.();
      await session.waitForText("catalog stream completed", 10_000);
      expect(stream.cancelled).toBe(false);
      expect(gateway.requests).toHaveLength(1);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "Escape closes a visible slash menu without cancelling an active stream",
    async () => {
      const fixture = createSkillsMenuFixture();
      const stream: HeldSkillStream = { cancelled: false };
      gateway = startFakeGateway([() => heldSkillStreamResponse(stream)]);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath: fixture.stderrPath,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-active-slash-stream-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        },
        width: 72,
        height: 16,
      });
      await session.waitForComposer(10_000);

      await session.sendText("Keep this slash response active.");
      await waitForHeldSkillStream(stream);
      await session.waitForText("Thinking", 10_000);
      await session.sendLiteralText("/he");
      await session.waitForText("Esc Close", 10_000);

      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) =>
          pane.includes("Thinking") &&
          pane.includes("/he") &&
          !pane.includes("Esc Close"),
        5_000,
      );
      expect(stream.cancelled).toBe(false);

      stream.release?.();
      await session.waitForText("catalog stream completed", 10_000);
      expect(stream.cancelled).toBe(false);
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
    },
    TEST_TIMEOUT,
  );

  test(
    "file approval returns to the preserved skills catalog",
    async () => {
      const fixture = createSkillsMenuFixture();
      const target = join(fixture.workspace, "catalog-approval.txt");
      let releaseApproval: () => void = () => {};
      const approvalReady = new Promise<void>((resolve) => {
        releaseApproval = resolve;
      });
      gateway = startFakeGateway([
        async () => {
          await approvalReady;
          return fakeGatewayToolCall("catalog_approval", "write_file", {
            path: "catalog-approval.txt",
            content: "must not be written\n",
          });
        },
        fakeGatewayFinalText("catalog approval completed"),
      ]);
      const stderrPath = join(fixture.home, "catalog-approval.stderr");
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-catalog-approval-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_PERMISSION_MODE: "ask",
          FX_AUTO_UPGRADE: "0",
        },
        width: 120,
        height: 32,
      });
      await session.waitForComposer(10_000);

      await session.sendText("Request the catalog approval fixture.");
      await session.waitForText("Thinking", 10_000);
      await session.sendLiteralText("$");
      await waitForSkillsMenu(session, 4);

      releaseApproval();
      await session.waitForText("catalog-approval.txt", 10_000);
      expect(await session.capturePane()).not.toContain("↑↓ Navigate");

      await session.sendKeys("3");
      let grid = await waitForSkillsMenu(session, 4);
      expect(composerContains(grid.join("\n"), "$")).toBe(true);
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-[");
      await session.waitForText("catalog approval completed", 10_000);
      expect(existsSync(target)).toBe(false);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "selected dollar skill token stays formatted after submit and reflow",
    async () => {
      const fixture = createSkillsMenuFixture();
      const gateway = startFakeGateway([fakeGatewayFinalText("skill token prompt complete")]);
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fake-skill-token-key",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          width: 120,
          height: 32,
        });
        await session.waitForComposer(10_000);

        await session.sendKeys("-l '$man'");
        await session.waitForText("managed-menu", 5_000);
        await session.sendKeys("Enter");
        await session.waitForPane((pane) => composerContains(pane, "managed-menu"), 5_000);
        await session.sendKeys("-l 'please'");

        let escapes = await session.capturePaneEscapes();
        expect(escapes).toContain("managed-menu");
        expect(escapes).not.toContain("$managed-menu please");

        await session.sendKeys("Enter");
        await session.waitForText("skill token prompt complete", 10_000);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.body).toContain("$managed-menu please");
        expect(gateway.requests[0]!.body).toContain(
          join(fixture.home, ".fx", "skills", "managed-menu"),
        );

        let history = capturePaneHistory(session, -200);
        expect(history).toMatch(/(?:┃|❯) managed-menu please/);
        expect(history).not.toMatch(/(?:┃|❯) \$managed-menu please/);
        escapes = await session.captureFullScrollbackEscapes();
        let submittedRows = submittedSkillRows(escapes);
        expect(submittedRows).toHaveLength(1);
        expect(submittedRows[0]).toContain("\x1b[38;5;252mmanaged-menu");

        await session.resizeWindow(80, 24);
        history = capturePaneHistory(session, -200);
        expect(history).toMatch(/(?:┃|❯) managed-menu please/);
        expect(history).not.toMatch(/(?:┃|❯) \$managed-menu please/);
        escapes = await session.captureFullScrollbackEscapes();
        submittedRows = submittedSkillRows(escapes);
        expect(submittedRows).toHaveLength(1);
        expect(submittedRows[0]).toContain("\x1b[38;5;252mmanaged-menu");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    TEST_TIMEOUT,
  );

  test(
    "shell variable with no skill match keeps spaces and submits raw",
    async () => {
      const fixture = createMentionGuardFixture();
      const gateway = startFakeGateway([fakeGatewayFinalText("raw variable prompt complete")]);
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fake-mention-guard-key",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          width: 120,
          height: 32,
        });
        await session.waitForComposer(10_000);

        await session.sendKeys("-l 'Explain echo '");
        await session.sendKeys("-l '$HOME'");
        await session.waitForPane(
          (pane) =>
            composerContains(pane, "Explain echo $HOME") &&
            pane.includes("𝒇x") &&
            !pane.includes("No skills found."),
          5_000,
        );
        await session.sendKeys("-l ' please'");
        await session.waitForText("Explain echo $HOME please", 5_000);
        expect(await session.capturePane()).not.toContain("Space details");

        await session.sendKeys("Enter");
        await session.waitForText("raw variable prompt complete", 10_000);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.body).toContain("Explain echo $HOME please");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    TEST_TIMEOUT,
  );

  test(
    "space after matched dollar token inserts and closes the menu",
    async () => {
      const fixture = createMentionGuardFixture();
      const gateway = startFakeGateway([fakeGatewayFinalText("mention space prompt complete")]);
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fake-mention-space-key",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          width: 120,
          height: 32,
        });
        await session.waitForComposer(10_000);

        await session.sendKeys("-l '$man'");
        await session.waitForText("managed-menu", 5_000);
        await session.sendKeys("-l ' now'");
        await session.waitForText("$man now", 5_000);
        expect(await session.capturePane()).not.toContain("Space details");

        await session.sendKeys("Enter");
        await session.waitForText("mention space prompt complete", 10_000);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.body).toContain("$man now");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    TEST_TIMEOUT,
  );

  test(
    "selected duplicate skill binds one advertised location",
    async () => {
      const fixture = createExactSkillsMenuFixture();
      const tracePath = join(fixture.root, "trace.log");
      const stderrPath = join(fixture.root, "stderr.log");
      gateway = startFakeGateway([
        fakeGatewayFinalText("exact picker selection complete"),
      ]);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-exact-picker-key",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "skill,skills,agent,core",
        },
        stderrPath,
        width: 120,
        height: 36,
      });

      const diagnosticSummary =
        "Skills: 1 discovery issue; some skills may be missing (ctrl o to view)";
      await session.waitForText(diagnosticSummary, 10_000);
      await session.waitForComposer(10_000);
      expect(await session.captureFullScrollback()).not.toContain(
        "skill discovery warning:",
      );
      await session.sendKeys("C-o");
      await session.waitForText("skill discovery warning:", 5_000);
      const tracePathPattern = tracePath
        .split("/")
        .map((segment) => segment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
        .join("/\\s*");
      expect((await session.capturePane()).replace(/\s+/g, " ")).toMatch(
        new RegExp(`see "${tracePathPattern}" for details`),
      );
      await session.sendKeys("Right");
      await session.waitForText("Full detail · ←/→ switch · ctrl o close", 5_000);
      await session.sendKeys("C-o");
      await session.waitForComposer(5_000);
      const startupDiagnosticCount = fileMarkerCount(
        tracePath,
        fixture.malformedMarker,
      );
      expect(startupDiagnosticCount).toBeGreaterThan(0);

      await session.sendLiteralText("$exact-picker");
      await session.waitForPane(
        (pane) => countOccurrences(pane, "exact-picker") >= 3,
        5_000,
      );
      await session.sendKeys("Down");
      const selectedRows = (await session.capturePaneEscapes())
        .split("\n")
        .filter((line) =>
          line.includes(SELECTED_COMPLETION_SGR) && line.includes("exact-picker")
        );
      expect(selectedRows).toHaveLength(1);
      expect(selectedRows[0]).toContain("Workspace");
      await session.sendKeys("Enter");
      await session.waitForPane((pane) => composerContains(pane, "exact-picker"), 5_000);
      await session.sendLiteralText(" inspect the exact selection");
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) =>
          pane.includes("exact picker selection complete") && hasEmptyComposer(pane),
        15_000,
      );

      expect(gateway.requests).toHaveLength(1);
      const firstPrompt = gatewayPromptText(gateway.requests[0]!.body);
      expect(firstPrompt).toContain("Explicitly invoked skill content for this query");
      expect(firstPrompt).toContain('<skill_content name="exact-picker"');
      expect(firstPrompt).toContain(fixture.workspaceDescription);
      expect(firstPrompt).toContain(fixture.bodyB);
      expect(firstPrompt).not.toContain(fixture.bodyA);

      expect(
        countOccurrences(
          await session.captureFullScrollback(),
          diagnosticSummary,
        ),
      ).toBe(1);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    45_000,
  );

  test(
    "slash menu highlight reaches bottom before the list scrolls",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-slash-highlight-")));
      workDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });
      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 100,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("/");
      await session.waitForText("Commands 39", 5_000);

      for (let i = 0; i < 5; i += 1) {
        await session.sendKeys("Down");
      }

      const selectedRow = selectedSlashRowIndex(await session.capturePaneEscapes());
      expect(selectedRow).toBeGreaterThanOrEqual(5);

      await session.sendKeys("Down");
      await session.sendKeys("Up");

      const reversedRow = selectedSlashRowIndex(await session.capturePaneEscapes());
      expect(reversedRow).toBe(4);
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "submitting clear from the slash menu does not crash",
    async () => {
      session = await TmuxSession.create({ width: 100, height: 30 });
      await session.waitForComposer(10_000);

      await session.sendKeys("-l '/clear'");
      await session.waitForText("start a fresh session and keep background processes", 5_000);
      await session.sendKeys("Enter");
      await session.waitForComposer(5_000);

      expect(session.isAlive()).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "slash menu remains alive when descriptions clip in a narrow terminal",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-slash-narrow-menu-e2e-"));
      workDirs.push(workDir);
      const home = join(workDir, "home");
      const workspace = join(workDir, "workspace");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });

      session = await TmuxSession.create({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
        width: 42,
        height: 18,
      });
      await session.waitForComposer(10_000);

      await session.sendKeys("-l '/mo'");
      await session.waitForText("/model", 5_000);

      const grid = await session.capturePaneGrid();
      const pane = grid.join("\n");
      expect(pane).toContain("Commands 2");
      expect(pane).toContain("/model");
      expect(pane).toContain("…");
      expect(pane).not.toMatch(/\sModel\s*$/m);
      expect(session.isAlive()).toBe(true);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );
});
