import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { logLines, onlySessionId, savedSession, sessionDir } from "./saved-sessions";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
const tmuxTest = test.skipIf(!HAS_TMUX);
const TIMEOUT = 90_000;
const COMPOSER_LIMIT_PASTE_TIMEOUT = TIMEOUT * 3;
const COMPOSER_BYTE_LIMIT = 8 * 1024 * 1024;
const PASTE_START = ["1b", "5b", "32", "30", "30", "7e"] as const;
const PASTE_END = ["1b", "5b", "32", "30", "31", "7e"] as const;
const SUFFIX_IGNORED_NOTICE = "Input that arrived right after the paste was ignored.";
const MANAGED_REVIEW_BODY = "GROUP_C_MANAGED_REVIEW_BODY";
const WORKSPACE_REVIEW_BODY = "GROUP_C_WORKSPACE_REVIEW_BODY";

let session: TmuxSession | null = null;
let root: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let fixtureImagePath: string | null = null;
let isolatedHome: string | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
  if (isolatedHome) cleanupIsolatedTestHome(isolatedHome);
  isolatedHome = null;
  stderrPath = null;
  fixtureImagePath = null;
});

async function startFx(
  withGateway: boolean,
  responseCount = 1,
  duplicateReview = false,
  traceScopes?: string,
  envOverrides?: Record<string, string | undefined> | ((fixtureRoot: string) => Record<string, string | undefined>),
  gatewayResponses?: Parameters<typeof startFakeGateway>[0],
  foregroundShell = false,
): Promise<TmuxSession> {
  root = realpathSync(mkdtempSync(join(tmpdir(), "fx-edit-contracts-")));
  const home = isolatedHome = realpathSync(createIsolatedTestHome());
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({}),
  );
  stderrPath = join(root, "stderr.log");
  writeFileSync(stderrPath, "");
  const tracePath = traceScopes ? join(root, "trace.log") : undefined;
  if (tracePath) writeFileSync(tracePath, "");
  fixtureImagePath = join(workspace, "i.png");
  writeFileSync(
    fixtureImagePath,
    Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      "base64",
    ),
  );
  writeFileSync(join(workspace, "target.txt"), "target\n");
  const skillRoot = join(home, ".fx", "skills", "review");
  mkdirSync(skillRoot, { recursive: true });
  writeFileSync(
    join(skillRoot, "SKILL.md"),
    `---\nname: review\ndescription: Review the current change\n---\n${MANAGED_REVIEW_BODY}\n`,
  );
  if (duplicateReview) {
    const workspaceSkillRoot = join(workspace, "skills", "review-workspace");
    mkdirSync(workspaceSkillRoot, { recursive: true });
    writeFileSync(
      join(workspaceSkillRoot, "SKILL.md"),
      `---\nname: review\ndescription: Review from the workspace\n---\n${WORKSPACE_REVIEW_BODY}\n`,
    );
  }

  if (withGateway) {
    gateway = startFakeGateway(
      gatewayResponses ?? Array.from(
        { length: responseCount },
        (_, index) => fakeGatewayFinalText(`edit contract complete ${index + 1}`),
      ),
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
          // Exercise composer byte limits independently of context compaction.
          context_window: 16_000_000,
          max_tokens: 64_000,
        }],
      },
    );
  }

  session = await TmuxSession.create({
    cmd: foregroundShell ? "/bin/bash --noprofile --norc -i" : FX_BIN,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: withGateway ? "fake-edit-contract-key" : undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway?.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway?.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: gateway
        ? `${gateway.baseUrl}/coding-agent/v1/models`
        : undefined,
      FX_MODEL: withGateway ? FAKE_GATEWAY_MODEL : undefined,
      FX_AUTO_UPGRADE: "0",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: traceScopes,
      VISUAL: undefined,
      EDITOR: undefined,
      ...(foregroundShell ? { PS1: "FX_EDIT_JOB_SHELL_PROMPT> ", PROMPT_COMMAND: "" } : {}),
      ...(typeof envOverrides === "function" ? envOverrides(root) : envOverrides),
    },
    width: 112,
    height: 32,
    stderrPath: foregroundShell ? undefined : stderrPath,
  });
  if (foregroundShell) {
    await session.waitForText("FX_EDIT_JOB_SHELL_PROMPT>", TIMEOUT);
    await session.sendText(`${JSON.stringify(FX_BIN)} 2>${JSON.stringify(stderrPath)}`);
  }
  await session.waitForComposer(TIMEOUT);
  return session;
}

/// The folders fx captures prompt images into, outside the session store,
/// until a turn saves them (D44).
function imageSnapshotDirs(): string[] {
  const tmp = realpathSync("/tmp");
  return readdirSync(tmp).filter((name) => name.startsWith("fx-image-snapshots-")).map((name) => join(tmp, name));
}

/// The image this run captured: the one snapshot folder made since `before`.
function historyImageSnapshotPath(before: Set<string>): string {
  const made = imageSnapshotDirs().filter((dir) => !before.has(dir));
  expect(made).toHaveLength(1);
  const imageDir = made[0]!;
  const snapshotNames = readdirSync(imageDir)
    .filter((name) => name.endsWith(".bin"));
  expect(snapshotNames).toHaveLength(1);
  return join(imageDir, snapshotNames[0]!);
}

async function waitForGatewayRequest(count = 1): Promise<void> {
  await waitForGatewayRequestWithin(TIMEOUT, count);
}

async function waitForCompletedTurn(active: TmuxSession, count: number): Promise<void> {
  await active.waitForPane(
    (pane) =>
      pane.includes(`edit contract complete ${count}`) &&
      hasEmptyComposer(pane) &&
      !pane.includes("esc interrupt") &&
      !pane.includes("Thinking"),
    TIMEOUT,
  );
}

async function waitForGatewayRequestWithin(
  timeout: number,
  count = 1,
): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if ((gateway?.requestCount() ?? 0) >= count) return;
    await Bun.sleep(25);
  }
  throw new Error("Timed out waiting for fake Gateway request");
}

async function waitForModelRequest(count = 1): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    if ((gateway?.modelRequests.length ?? 0) >= count) return;
    await Bun.sleep(25);
  }
  throw new Error("Timed out waiting for fake Gateway model request");
}

async function waitForTraceOrExit(
  active: TmuxSession,
  expected: string,
  timeout = TIMEOUT,
): Promise<void> {
  const tracePath = join(root!, "trace.log");
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (!active.isAlive()) return;
    if (readFileSync(tracePath, "utf8").includes(expected)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for trace: ${expected}`);
}

function userParts(requestIndex = 0): Array<{
  type: string;
  text?: string;
}> {
  const body = JSON.parse(gateway!.requests[requestIndex]!.body) as {
    prompt: Array<{
      role: string;
      content: Array<{ type: string; text?: string }>;
    }>;
  };
  const message = body.prompt.findLast((entry) => entry.role === "user");
  return message?.content ?? [];
}

// The request names each attached image's saved file ahead of the prompt.
const IMAGE_LOCATION_NOTES = /^(\[Image #\d+ \(image\/[a-z]+\) [^\n]*\]\n)+/;

function requestUserText(requestIndex: number): string {
  return userParts(requestIndex).find((part) => part.type === "text")?.text ??
    "";
}

// A named skill's text follows the typed prompt on the turn's message (D95 in
// tests/tla/session_manager/system-design.md).
const NAMED_SKILL_TEXT = /\n\nExplicitly invoked skill content for this query:\n[\s\S]*$/;

function finalUserText(requestIndex = 0): string {
  return requestUserText(requestIndex).replace(IMAGE_LOCATION_NOTES, "").replace(NAMED_SKILL_TEXT, "");
}

function imageLocationNotes(requestIndex = 0): string {
  return requestUserText(requestIndex).match(IMAGE_LOCATION_NOTES)?.[0] ?? "";
}

function nestedText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(nestedText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [
      nestedText(value.text),
      nestedText(value.value),
      nestedText(value.content),
    ].join("");
  }
  return "";
}

function gatewayPromptText(requestIndex = 0): string {
  const body = JSON.parse(gateway!.requests[requestIndex]!.body) as {
    prompt: Array<{ content: unknown }>;
  };
  return body.prompt.map((message) => nestedText(message.content)).join("\n");
}

function expectCleanRuntime(active: TmuxSession): void {
  expect(active.isAlive()).toBe(true);
  expect(readFileSync(stderrPath!, "utf8")).toBe("");
}

function textHex(text: string): string[] {
  return Array.from(new TextEncoder().encode(text), (byte) =>
    byte.toString(16).padStart(2, "0")
  );
}

async function pasteExact(active: TmuxSession, text: string): Promise<void> {
  await active.sendHexBytes([
    ...PASTE_START,
    ...textHex(text),
    ...PASTE_END,
  ]);
}

/// Pastes `text` and presses `key` in one tmux command, so the key reaches fx
/// right behind the paste's end marker, as when a user presses a key while a
/// large paste is still arriving.
function pasteThenKey(active: TmuxSession, text: string, key: string): void {
  const buffer = `${active.name}-paste-then-key`;
  execFileSync("tmux", ["load-buffer", "-b", buffer, "-"], {
    input: text,
    stdio: ["pipe", "pipe", "pipe"],
  });
  execFileSync("tmux", [
    "paste-buffer", "-d", "-p", "-b", buffer, "-t", active.name,
    ";", "send-keys", "-t", active.name, key,
  ], { stdio: "pipe" });
}

async function selectReviewSkill(
  active: TmuxSession,
  selectWorkspace = false,
): Promise<void> {
  await active.sendLiteralText("$review");
  await active.waitForText("enter use", TIMEOUT);
  if (selectWorkspace) await active.sendKeys("Down");
  await active.sendKeys("Enter");
}

tmuxTest(
  "composer shortcuts pressed immediately after Escape preserve input order",
  async () => {
    const active = await startFx(true, 2);

    await active.sendLiteralText("abc");
    await active.sendHexBytes(["1b", "01", "58"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest(1);
    expect(finalUserText(0)).toBe("Xabc");

    await waitForCompletedTurn(active, 1);
    await active.sendLiteralText("/");
    await active.sendHexBytes(["1b", "15", ...textHex("after")]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);
    expect(finalUserText(1)).toBe("after");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "CRLF paste reaches Gateway as one logical newline",
  async () => {
    const active = await startFx(true);

    await pasteExact(active, "CRLF_SENTINEL_A\r\nCRLF_SENTINEL_B");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("CRLF_SENTINEL_A\nCRLF_SENTINEL_B");
    expect(await active.captureFullScrollback()).not.toContain(SUFFIX_IGNORED_NOTICE);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "embedded paste terminator cannot execute its same-epoch suffix",
  async () => {
    const active = await startFx(true, 1, false, "input,theme,resize,native_clear");
    await active.sendLiteralText("PRESERVED_DRAFT");

    await active.sendHexBytes([
      ...PASTE_START,
      ...PASTE_END,
      ...textHex("/version"),
      "0d",
      ...PASTE_END,
    ]);
    // "/version", "\r", and the terminal's real end marker all follow the
    // embedded one in the same delivery.
    await waitForTraceOrExit(
      active,
      "paste suffix dropped owner=composer bytes=15 reason=same_delivery_as_end_marker",
    );
    await active.waitForText(SUFFIX_IGNORED_NOTICE, TIMEOUT);

    expect(gateway?.requestCount()).toBe(0);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).not.toMatch(/[*✓!✗⊘i] version:/);
    expect(composerContains(scrollback, "/version")).toBe(false);
    await active.waitForText("PRESERVED_DRAFT", TIMEOUT);

    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe("PRESERVED_DRAFT");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "active paste keeps a trailing escape sequence out of response parsers",
  async () => {
    const active = await startFx(true, 1, false, "input,theme,resize,native_clear");
    await active.sendLiteralText("ESCAPE_DRAFT");

    await active.sendHexBytes([
      ...PASTE_START,
      ...textHex("paste"),
      ...PASTE_END,
      "1b",
      "5b",
      ...PASTE_END,
    ]);
    await waitForTraceOrExit(
      active,
      "paste suffix dropped owner=composer bytes=8 reason=same_delivery_as_end_marker",
    );

    expect(gateway?.requestCount()).toBe(0);
    await active.waitForPane((pane) => composerContains(pane, "ESCAPE_DRAFTpaste"), TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe("ESCAPE_DRAFTpaste");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Enter in the same delivery as a paste keeps the paste and does not submit",
  async () => {
    const active = await startFx(true, 1, false, "input");
    await active.sendLiteralText("DRAFT ");

    await active.sendHexBytes([
      ...PASTE_START,
      ...textHex("PASTED_BODY"),
      ...PASTE_END,
      "0d",
    ]);
    await waitForTraceOrExit(active, "paste end owner=composer bytes=11");
    await waitForTraceOrExit(
      active,
      "paste suffix dropped owner=composer bytes=1 reason=same_delivery_as_end_marker",
    );
    await active.waitForText(SUFFIX_IGNORED_NOTICE, TIMEOUT);
    await active.waitForPane((pane) => composerContains(pane, "DRAFT PASTED_BODY"), TIMEOUT);
    expect(gateway?.requestCount()).toBe(0);

    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe("DRAFT PASTED_BODY");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "keys typed in the same delivery as a paste are not added to the draft",
  async () => {
    const active = await startFx(true, 1, false, "input");

    await active.sendHexBytes([
      ...PASTE_START,
      ...textHex("PASTED_BODY"),
      ...PASTE_END,
      ...textHex("TYPED"),
    ]);
    await waitForTraceOrExit(
      active,
      "paste suffix dropped owner=composer bytes=5 reason=same_delivery_as_end_marker",
    );
    await active.waitForText(SUFFIX_IGNORED_NOTICE, TIMEOUT);
    await active.waitForPane((pane) => composerContains(pane, "PASTED_BODY"), TIMEOUT);
    expect(composerContains(await active.capturePane(), "TYPED")).toBe(false);

    // Keys typed after the paste has been read are ordinary input again.
    await active.sendLiteralText(" AFTER");
    await active.waitForPane((pane) => composerContains(pane, "PASTED_BODY AFTER"), TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe("PASTED_BODY AFTER");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "a large paste with Enter pressed right behind it stays in the draft",
  async () => {
    const active = await startFx(true, 1, false, "input");
    const lines = Array.from(
      { length: 400 },
      (_, index) => `log line ${String(index).padStart(5, "0")} GET /assets/chunk.js 200 340ms`,
    );
    const body = lines.join("\n");
    await active.sendLiteralText("is there a download optimization to make? ");

    pasteThenKey(active, body, "Enter");
    await waitForTraceOrExit(active, `paste end owner=composer bytes=${body.length}`);
    await waitForTraceOrExit(
      active,
      "paste suffix dropped owner=composer bytes=1 reason=same_delivery_as_end_marker",
    );
    await active.waitForText(SUFFIX_IGNORED_NOTICE, TIMEOUT);
    await active.waitForPane(
      (pane) =>
        composerContains(pane, "is there a download optimization to make?") &&
        composerContains(pane, "[Pasted text #1, 400 lines]"),
      TIMEOUT,
    );
    expect(gateway?.requestCount()).toBe(0);

    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe(`is there a download optimization to make? ${body}`);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "direct multiline paste reaches Gateway with boundary whitespace intact",
  async () => {
    const active = await startFx(true);
    const exact = "    if True:\n        print(\"x\")\n";

    await pasteExact(active, exact);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(exact);
    const submitted = (await active.captureFullScrollback())
      .split("\n")
      .find((line) => line.includes("if True:"));
    expect(submitted).toContain("┃     if True:");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "tiny clipped composer exposes hidden rows and preserves the submitted draft",
  async () => {
    const active = await startFx(true);
    const visibleDraft = "GROUP_I_HIDDEN_ROW\nGROUP_I_CURSOR_ROW";
    const exact = `${visibleDraft}\n`;
    await active.resizeWindow(40, 8, 500);

    await pasteExact(active, visibleDraft);
    let pane = await active.waitForPane(
      (value) => value.includes("↑") && value.includes("GROUP_I_CURSOR_ROW"),
      TIMEOUT,
    );
    expect(pane).not.toContain("GROUP_I_HIDDEN_ROW");

    await pasteExact(active, "\n");
    pane = await active.waitForPane(
      (value) => value.includes("↑") && !value.includes("GROUP_I_CURSOR_ROW"),
      TIMEOUT,
    );
    expect(pane).not.toContain("GROUP_I_HIDDEN_ROW");

    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe(exact);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "absolute non-image path at prompt start reaches Gateway",
  async () => {
    const active = await startFx(true);
    const path = realpathSync(join(root!, "workspace", "target.txt"));
    const prompt = `${path} please inspect`;

    await active.sendLiteralText(prompt);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(prompt);
    expect(await active.captureFullScrollback()).not.toContain(
      "Unknown command",
    );
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "typed prompt above the old 4 KiB limit reaches Gateway byte-for-byte",
  async () => {
    const active = await startFx(true);
    const prompt = `BEGIN-${"x".repeat(8192)}-END`;

    await waitForModelRequest();
    await active.sendLiteralText(prompt);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(prompt);
    expect(gateway!.modelRequests).toHaveLength(1);
    expect(JSON.parse(gateway!.requests[0]!.body)).toMatchObject({
      maxOutputTokens: 64_000,
    });
    expect(await active.captureFullScrollback()).not.toContain(
      "local prompt safety limit",
    );
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "multi-megabyte bracketed paste survives edits and resize byte-for-byte",
  async () => {
    const active = await startFx(true, 1, false, "input");
    const prompt = `PASTE-BEGIN-${"x".repeat(4 * 1024 * 1024 + 1)}-PASTE-END`;

    await waitForModelRequest();
    await active.pasteText(prompt);
    await waitForTraceOrExit(active, "paste end owner=composer");
    await active.sendKeys("Home");
    await active.sendLiteralText("HEAD-EDIT-");
    await active.sendKeys("End");
    await active.sendLiteralText("-TAIL-EDIT");
    await active.resizeWindow(42, 16);
    await active.resizeWindow(112, 32);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(`HEAD-EDIT-${prompt}-TAIL-EDIT`);
    expect(gateway!.modelRequests).toHaveLength(1);
    expect(JSON.parse(gateway!.requests[0]!.body)).toMatchObject({
      maxOutputTokens: 64_000,
    });
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "expanded paste accepts the exact composer byte limit",
  async () => {
    const active = await startFx(true, 1, false, "input");
    const rune = "🧪";
    const runeBytes = Buffer.byteLength(rune);
    const firstPasteBytes = COMPOSER_BYTE_LIMIT / 2 - runeBytes;
    const secondPasteBytes = COMPOSER_BYTE_LIMIT - firstPasteBytes;
    const firstPaste = rune.repeat(firstPasteBytes / runeBytes);
    const secondPaste = rune.repeat(secondPasteBytes / runeBytes);
    const prompt = firstPaste + secondPaste;
    expect(Buffer.byteLength(prompt)).toBe(COMPOSER_BYTE_LIMIT);

    await waitForModelRequest();
    await active.pasteText(firstPaste);
    await waitForTraceOrExit(
      active,
      `paste end owner=composer bytes=${firstPasteBytes}`,
      COMPOSER_LIMIT_PASTE_TIMEOUT,
    );
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.pasteText(secondPaste);
    await waitForTraceOrExit(
      active,
      `paste end owner=composer bytes=${secondPasteBytes}`,
      COMPOSER_LIMIT_PASTE_TIMEOUT,
    );
    await active.waitForText("[Pasted text #2, 1 line]", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequestWithin(COMPOSER_LIMIT_PASTE_TIMEOUT);

    expect(finalUserText()).toBe(prompt);
    expect(await active.captureFullScrollback()).not.toContain(
      "local prompt safety limit",
    );
    expectCleanRuntime(active);
  },
  COMPOSER_LIMIT_PASTE_TIMEOUT * 2,
);

tmuxTest(
  "expanded paste rejects one byte over the composer limit and recovers",
  async () => {
    const active = await startFx(true);

    await waitForModelRequest();
    await active.pasteText("x".repeat(COMPOSER_BYTE_LIMIT + 1));
    await active.waitForText("local prompt safety limit", TIMEOUT);
    expect(gateway!.requestCount()).toBe(0);

    await active.sendLiteralText("RECOVERY_PROMPT");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("RECOVERY_PROMPT");
    expectCleanRuntime(active);
  },
  TIMEOUT * 2,
);

tmuxTest(
  "long paste submitted at a full bottom edge leaves no preview fragment in scrollback",
  async () => {
    root = realpathSync(mkdtempSync(join(tmpdir(), "fx-paste-submit-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
    stderrPath = join(root, "stderr.log");
    writeFileSync(stderrPath, "");

    // The first answer overflows the viewport so its summary sits mid-line at
    // the band bottom; the submitted card is taller than the screen.
    const filler = Array.from(
      { length: 240 },
      (_, index) => `FILLER_ANSWER_LINE_${String(index).padStart(3, "0")}`,
    ).join("\n");
    const dynamicGateway = startDynamicFakeGateway((body) => {
      writeFileSync(join(root!, `request-${dynamicGateway.requests.length}.json`), body);
      return fakeGatewayFinalText(
        dynamicGateway.requests.length === 1 ? filler : "SECOND_ANSWER_OK",
      );
    });
    const pasteLines = ["# Pending card probe", ""];
    for (let index = 1; index <= 380; index++) {
      pasteLines.push(`- probe line ${String(index).padStart(3, "0")}`);
    }
    pasteLines.push("", "- PENDING_PROBE_LAST_LINE");

    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: workspace,
      width: 168,
      height: 75,
      isolated: true,
      remainOnExit: true,
      minimumHistoryLines: 20_000,
      stderrPath,
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-paste-submit-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_E2E_DISABLE_DOTENV: "1",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_PERMISSION_MODE: "full-access",
        FX_GATEWAY_BASE_URL: dynamicGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: dynamicGateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: dynamicGateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${dynamicGateway.baseUrl}/coding-agent/v1/models`,
      },
    });
    try {
      await session.waitForStableComposer(20_000);
      await session.sendText("Fill the screen.");
      await session.waitForText("FILLER_ANSWER_LINE_239", TIMEOUT);
      await session.waitForStableComposer(20_000);
      const beforeSubmit = await session.captureFullScrollback();
      const priorSummary = beforeSubmit
        .split("\n")
        .find((line) => line.includes("↑") && line.includes("↓") && line.includes("("))
        ?.trim();
      expect(priorSummary).toBeTruthy();

      await session.pasteText(pasteLines.join("\n"));
      await session.waitForText("Pasted text", 15_000);
      await session.sendKeys("Enter");
      await session.waitForText("SECOND_ANSWER_OK", TIMEOUT);
      await session.waitForStableComposer(20_000);
      const after = await session.captureFullScrollback();

      const cardTailCandidates = after
        .split("\n")
        .filter((line) => line.trim().startsWith("┃ - PEND"));
      expect(
        cardTailCandidates.filter(
          (line) => line.trim() === "┃ - PENDING_PROBE_LAST_LINE",
        ),
      ).toHaveLength(1);
      expect(
        cardTailCandidates.filter(
          (line) => line.trim() !== "┃ - PENDING_PROBE_LAST_LINE",
        ),
      ).toHaveLength(0);
      expect(
        after.split("\n").filter((line) => line.trim() === priorSummary),
      ).toHaveLength(1);
      expect(dynamicGateway.requests).toHaveLength(2);
      expectCleanRuntime(session);
    } finally {
      dynamicGateway.stop();
    }
  },
  TIMEOUT * 2,
);

tmuxTest(
  "terminal characters stay atomic and Ctrl+K joins at EOL",
  async () => {
    const active = await startFx(false);

    await active.sendLiteralText("A🇺🇸B");
    await active.sendKeys("Left BSpace");
    let pane = await active.waitForPane((value) => value.includes("AB"), TIMEOUT);
    expect(pane).not.toContain("🇺");
    expect(pane).not.toContain("🇸");

    await active.sendKeys("End C-u");
    await pasteExact(active, "alpha\nbeta\ngamma");
    await active.sendKeys("Up");
    await active.sendHexBytes(["0b"]);
    pane = await active.waitForPane(
      (value) => value.includes("alpha") && value.includes("betagamma"),
      TIMEOUT,
    );
    expect(pane).toContain("betagamma");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Home End and control aliases stay on the current logical line",
  async () => {
    const active = await startFx(true, 2);

    await pasteExact(active, "FIRST\nSECOND\nTHIRD");
    await active.sendKeys("Up Home");
    await active.sendLiteralText("HOME_");
    await active.sendKeys("End");
    await active.sendLiteralText("_END");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText(0)).toBe("FIRST\nHOME_SECOND_END\nTHIRD");

    await waitForCompletedTurn(active, 1);
    await pasteExact(active, "ONE\nTWO\nTHREE");
    await active.sendKeys("Up");
    await active.sendHexBytes(["01"]);
    await active.sendLiteralText("CTRLA_");
    await active.sendHexBytes(["05"]);
    await active.sendLiteralText("_CTRLE");
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);

    expect(finalUserText(1)).toBe("ONE\nCTRLA_TWO_CTRLE\nTHREE");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "oversized paste edits occur outside the registered placeholder",
  async () => {
    const active = await startFx(true);
    const pasted = "P".repeat(1001);

    await pasteExact(active, pasted);
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendKeys("Left");
    await active.sendLiteralText("EDIT_SENTINEL");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(`EDIT_SENTINEL${pasted}`);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "vertical movement stays outside an oversized paste placeholder",
  async () => {
    const active = await startFx(true);
    const pasted = "V".repeat(1001);

    await pasteExact(active, "x\n");
    await pasteExact(active, pasted);
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendKeys("Up Left Right Down");
    await active.sendLiteralText("VERTICAL_SENTINEL");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(`x\nVERTICAL_SENTINEL${pasted}`);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+U and Ctrl+Y preserve oversized paste backing text",
  async () => {
    const active = await startFx(true);
    const pasted = "Y".repeat(1001);

    await pasteExact(active, pasted);
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendHexBytes(["15"]);
    await active.sendHexBytes(["19"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(pasted);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+U and repeated Ctrl+Y restore image attachments with fresh ids",
  async () => {
    const active = await startFx(true);

    await pasteExact(active, fixtureImagePath!);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendHexBytes(["15"]);
    await active.sendHexBytes(["19", "19"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("[Image #2][Image #3]");
    expect(userParts().filter((part) => part.type === "file")).toHaveLength(2);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+K and Ctrl+Y restore an image attachment",
  async () => {
    const active = await startFx(true);

    await pasteExact(active, fixtureImagePath!);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendKeys("Home");
    await active.sendHexBytes(["0b", "19"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("[Image #2]");
    expect(userParts().filter((part) => part.type === "file")).toHaveLength(1);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+U and Ctrl+Y preserve the selected duplicate skill source",
  async () => {
    const active = await startFx(true, 1, true);

    await selectReviewSkill(active, true);
    await active.sendLiteralText("inspect");
    await active.sendHexBytes(["15", "19"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("$review inspect");
    const prompt = gatewayPromptText();
    expect(prompt).toContain(WORKSPACE_REVIEW_BODY);
    expect(prompt).not.toContain(MANAGED_REVIEW_BODY);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "history recall keeps an oversized paste compact and editable",
  async () => {
    const active = await startFx(true, 2);
    const pasted = "H".repeat(4138);

    await pasteExact(active, pasted);
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    await active.waitForPane(
      (pane) =>
        pane.includes("edit contract complete") &&
        pane.includes("┃") &&
        !pane.includes("Thinking"),
      TIMEOUT,
    );

    await active.sendKeys("Up");
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendLiteralText(" EDIT_SHOULD_APPEAR");
    await active.waitForText("EDIT_SHOULD_APPEAR", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);

    expect(finalUserText(1)).toBe(`${pasted} EDIT_SHOULD_APPEAR`);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "history recall resubmits a real image under a fresh id",
  async () => {
    const active = await startFx(true, 2);

    await pasteExact(active, fixtureImagePath!);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendLiteralText(" describe history image");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    await active.waitForPane(
      (pane) =>
        pane.includes("edit contract complete") &&
        pane.includes("┃") &&
        !pane.includes("Thinking"),
      TIMEOUT,
    );

    await active.sendKeys("Up");
    await active.waitForText("[Image 2]", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);

    expect(finalUserText(0)).toBe("[Image #1] describe history image");
    expect(finalUserText(1)).toBe("[Image #2] describe history image");
    expect(userParts(0).filter((part) => part.type === "file")).toHaveLength(1);
    expect(userParts(1).filter((part) => part.type === "file")).toHaveLength(1);
    // Each turn names the session copy of its image, not the pasted path.
    const savedPaths = [0, 1].map((requestIndex) => {
      const note = imageLocationNotes(requestIndex).match(
        /^\[Image #(\d+) \(image\/png\) is saved at ("(?:[^"\\]|\\.)*")\.\]\n$/,
      );
      expect(note).not.toBeNull();
      expect(note![1]).toBe(String(requestIndex + 1));
      expect(gateway!.requests[requestIndex]!.body).not.toContain(fixtureImagePath!);
      const saved = JSON.parse(note![2]!) as string;
      expect(saved.startsWith(join(isolatedHome!, ".fx", "sessions"))).toBe(true);
      expect(readFileSync(saved)).toEqual(readFileSync(fixtureImagePath!));
      return saved;
    });
    // The session keeps those bytes once, as the blob named by their hash.
    expect(savedPaths[1]).toBe(savedPaths[0]);
    expect(savedPaths[0]!.startsWith(join(isolatedHome!, ".fx", "sessions", "v2"))).toBe(true);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

for (
  const scenario of [
    {
      name: "corrupt",
      damage(path: string) {
        writeFileSync(path, Buffer.from("corrupt history snapshot"));
      },
    },
    {
      name: "deleted",
      damage(path: string) {
        rmSync(path, { force: true });
      },
    },
  ]
) {
  tmuxTest(
    `history recall keeps its image when the captured file is ${scenario.name}`,
    async () => {
      const before = new Set(imageSnapshotDirs());
      const active = await startFx(true, 1, false, "prompt_history");

      await pasteExact(active, fixtureImagePath!);
      await active.waitForText("[Image 1]", TIMEOUT);
      await active.sendLiteralText(" remember image");
      await active.sendKeys("Enter");
      await waitForGatewayRequest();
      await active.waitForPane(
        (pane) =>
          pane.includes("edit contract complete") &&
          pane.includes("┃") &&
          !pane.includes("Thinking"),
        TIMEOUT,
      );

      // The recalled image carries its bytes, checked against its digest, so
      // the file fx captured it into is never read again (D84).
      scenario.damage(historyImageSnapshotPath(before));
      await active.sendKeys("Up");
      await active.waitForPane(
        (pane) => composerContains(pane, "remember image") && composerContains(pane, "[Image 1]"),
        TIMEOUT,
      );

      expect(active.isAlive()).toBe(true);
      expect(readFileSync(stderrPath!, "utf8")).toBe("");
      expect(readFileSync(join(root!, "trace.log"), "utf8")).not.toContain("event=recall_rejected");
    },
    TIMEOUT,
  );
}

tmuxTest(
  "history recall preserves duplicate skill provenance without showing it",
  async () => {
    const active = await startFx(true, 2, true);

    await selectReviewSkill(active, true);
    await active.waitForPane(
      (pane) =>
        composerContains(pane, "review") &&
        !composerContains(pane, "review · workspace skills/"),
      TIMEOUT,
    );
    await active.sendLiteralText("history skill");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    await active.waitForPane(
      (pane) =>
        pane.includes("edit contract complete") &&
        pane.includes("┃") &&
        !pane.includes("Thinking"),
      TIMEOUT,
    );

    await active.sendKeys("Up");
    await active.waitForPane(
      (pane) =>
        composerContains(pane, "history skill") &&
        composerContains(pane, "review") &&
        !composerContains(pane, "review · workspace skills/"),
      TIMEOUT,
    );
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);

    expect(finalUserText(1)).toBe("$review history skill");
    const prompt = gatewayPromptText(1);
    expect(prompt).toContain(WORKSPACE_REVIEW_BODY);
    expect(prompt).not.toContain(MANAGED_REVIEW_BODY);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "typed space claims a skill separator before forward deletion",
  async () => {
    const active = await startFx(true);

    await selectReviewSkill(active);
    await active.sendLiteralText(" ");
    await active.sendKeys("Home");
    await active.sendHexBytes(["04"]);
    await active.sendLiteralText("KEPT_SPACE");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("KEPT_SPACE ");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "typed paste lookalikes remain literal",
  async () => {
    const active = await startFx(true);
    const pasted = "L".repeat(1001);
    const lookalike = "[Pasted text #1, 999 lines]";

    await pasteExact(active, pasted);
    await active.sendLiteralText(` duplicate ${lookalike}`);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe(`${pasted} duplicate ${lookalike}`);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "image paths keep sentence punctuation and submit a file",
  async () => {
    const active = await startFx(true);

    await active.sendLiteralText("inspect i.png,");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("inspect [Image #1],");
    expect(userParts().filter((part) => part.type === "file")).toHaveLength(1);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "typed image lookalikes do not alias registered attachments",
  async () => {
    const active = await startFx(true);

    await pasteExact(active, fixtureImagePath!);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendLiteralText(" duplicate [Image #1]");
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("[Image #2] duplicate [Image #1]");
    expect(userParts().filter((part) => part.type === "file")).toHaveLength(1);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "Alt+D stops before an adjacent registered image",
  async () => {
    const active = await startFx(true);

    await pasteExact(active, `HEAD ${fixtureImagePath!} TAIL`);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendKeys("Home");
    await active.sendHexBytes(["1b", "64"]);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();

    expect(finalUserText()).toBe("[Image #1] TAIL");
    expect(userParts().filter((part) => part.type === "file")).toHaveLength(1);
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

tmuxTest(
  "skill entities survive file completion and stay atomic under word edits",
  async () => {
    const active = await startFx(true, 4);

    await selectReviewSkill(active);
    expect(await active.capturePane()).not.toContain("review ·");
    await active.sendLiteralText("@ta");
    await active.waitForText("target.txt", TIMEOUT);
    await active.sendKeys("Enter");
    await active.waitForText("@target.txt", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest(1);
    expect(finalUserText(0)).toBe("$review @target.txt ");

    await waitForCompletedTurn(active, 1);
    await selectReviewSkill(active);
    await active.sendLiteralText("hello");
    await active.sendHexBytes(["1b", "62", "1b", "62"]);
    await active.sendLiteralText("X");
    await active.sendKeys("Enter");
    await waitForGatewayRequest(2);
    expect(finalUserText(1)).toBe("X$review hello");

    await waitForCompletedTurn(active, 2);
    await selectReviewSkill(active);
    await active.sendHexBytes(["1b", "7f"]);
    await active.sendLiteralText("ALT_BACKSPACE_OK");
    await active.sendKeys("Enter");
    await waitForGatewayRequest(3);
    expect(finalUserText(2)).toBe("ALT_BACKSPACE_OK");

    await waitForCompletedTurn(active, 3);
    await selectReviewSkill(active);
    await active.sendKeys("Home");
    await active.sendHexBytes(["04"]);
    await active.sendLiteralText("DELETE_OK");
    await active.sendKeys("Enter");
    await waitForGatewayRequest(4);
    expect(finalUserText(3)).toBe("DELETE_OK");
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

// The editor is generated outside the workspace. Its files are handshakes, not
// timing guesses: captured documents/TTY state precede READY, and tests release
// a blocked editor only after observing the terminal state they exercise.
type EditorPlan = {
  prompt?: string;
  action?: "empty" | "missing-end" | "malformed-begin" | "duplicate-begin" | "nonzero" | "signal" | "atomic" | "symlink" | "hardlink" | "fifo" | "nul" | "utf8" | "oversize";
  mutateHistory?: boolean;
  interactive?: boolean;
  hold?: boolean;
  surviveInterrupt?: boolean;
  wrapper?: boolean;
  restopAfterContinue?: boolean;
};

type EditorCapture = {
  document: string;
  pid: number;
  path: string;
  cwd: string;
  argv: string[];
  fileMode: number;
  directoryMode: number;
  stdinTty: boolean;
  stdoutTty: boolean;
  canonical: boolean;
  echo: boolean;
  signals: boolean;
  shellSideEffect: boolean;
};

const EDITOR_ARGUMENT = "quoted argument $(touch SHOULD_NOT_RUN) ; literal";
const EDITOR_SCRIPT = String.raw`import json, os, re, signal, stat, sys, termios, time
from pathlib import Path
base = Path(__file__).parent
plan = json.loads((base / "plan.json").read_text())
number = 1 + len(list(base.glob("capture-*.json")))
p = Path(sys.argv[-1])
document = p.read_text()
attrs = termios.tcgetattr(0)
capture = dict(document=document, pid=os.getpid(), path=str(p), cwd=os.getcwd(), argv=sys.argv[1:],
    fileMode=stat.S_IMODE(p.stat().st_mode), directoryMode=stat.S_IMODE(Path.cwd().stat().st_mode),
    stdinTty=os.isatty(0), stdoutTty=os.isatty(1), canonical=bool(attrs[3] & termios.ICANON),
    echo=bool(attrs[3] & termios.ECHO), signals=bool(attrs[3] & termios.ISIG),
    shellSideEffect=(Path.cwd() / "SHOULD_NOT_RUN").exists())
capture_file = base / ("capture-%d.json" % number)
(base / "capture.pending").write_text(json.dumps(capture))
(base / "capture.pending").replace(capture_file)
print("FX_EDITOR_READY_%d" % number, flush=True)
if plan.get("surviveInterrupt"):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
if plan.get("restopAfterContinue"):
    def restop(_sig, _frame):
        signal.signal(signal.SIGCONT, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGSTOP)
    signal.signal(signal.SIGCONT, restop)
try:
    if plan.get("interactive"):
        first = input()
        (base / ("input-%d.json" % number)).write_text(json.dumps(dict(text=first, size=list(os.get_terminal_size(0)))))
        print("FX_EDITOR_INPUT_%d" % number, flush=True)
        input()
    while plan.get("hold") and not (base / "release").exists():
        time.sleep(0.01)
except KeyboardInterrupt:
    os._exit(130)
match = re.search(r"(?m)^(<!-- fx:prompt:begin:([0-9a-f]{32}) -->)\n([\s\S]*?)\n(<!-- fx:prompt:end:\2 -->)$", document)
if not match:
    raise RuntimeError("invalid host-generated prompt markers")
prompt = plan.get("prompt", match[3])
if plan.get("action") == "empty": prompt = " \t\n"
changed = document[:match.start(3)] + prompt + document[match.end(3):]
if plan.get("mutateHistory"):
    end = changed.index(match[4]) + len(match[4])
    changed = changed[:end] + "\n\n# Conversation history\nREFERENCE_WAS_REWRITTEN\n"
action = plan.get("action")
if action == "missing-end": changed = changed.replace(match[4], "")
if action == "malformed-begin": changed = changed.replace(match[1], match[1] + " not an exact line")
if action == "duplicate-begin": changed += "\n" + match[1] + "\n"
if action == "atomic":
    replacement = p.with_suffix(".replacement")
    replacement.write_text(changed)
    replacement.chmod(0o644)
    replacement.replace(p)
else:
    p.write_text(changed)
if action in ("symlink", "hardlink", "fifo"):
    p.unlink()
    if action == "symlink":
        p.symlink_to(base / "plan.json")
    elif action == "hardlink":
        os.link(base / "plan.json", p)
    else:
        os.mkfifo(p)
if action in ("nul", "utf8", "oversize"):
    payload = b"bad\x00prompt" if action == "nul" else b"\xff" if action == "utf8" else b"x" * (8 * 1024 * 1024 + 1)
    p.write_bytes(changed[:match.start(3)].encode() + payload + changed[match.start(3) + len(prompt):].encode())
# An editor backup must be removed along with the document on every outcome.
(p.parent / "editor-backup.md").write_text(document)
if action == "signal": os.kill(os.getpid(), signal.SIGTERM)
if action == "nonzero": sys.exit(7)
`;

function editorDirectory(): string {
  return join(root!, "editor fixture");
}

function setEditorPlan(plan: EditorPlan): void {
  writeFileSync(join(editorDirectory(), "plan.json"), JSON.stringify(plan));
}

function scriptedEditor(plan: EditorPlan = {}): (fixtureRoot: string) => Record<string, string> {
  return (fixtureRoot) => {
    const dir = join(fixtureRoot, "editor fixture");
    mkdirSync(dir);
    const script = join(dir, "script.py");
    writeFileSync(script, EDITOR_SCRIPT);
    writeFileSync(join(dir, "plan.json"), JSON.stringify(plan));
    const python = execFileSync("python3", ["-c", "import sys; print(sys.executable)"], { encoding: "utf8" }).trim();
    const launcher = join(dir, "editor with spaces.sh");
    const shellQuote = (value: string) => `'${value.replace(/'/g, "'\\''")}'`;
    writeFileSync(launcher, plan.wrapper
      ? `#!/bin/sh\ntrap ':' INT\n${shellQuote(python)} ${shellQuote(script)} "$@"\n`
      : `#!/bin/sh\nexec ${shellQuote(python)} ${shellQuote(script)} "$@"\n`);
    chmodSync(launcher, 0o700);
    return {
      VISUAL: `${JSON.stringify(launcher)} ${JSON.stringify(EDITOR_ARGUMENT)}`,
      // A selected VISUAL must not silently fall back to EDITOR.
      EDITOR: "/no-such-fx-fallback-editor",
    };
  };
}

async function waitForEditorFile(name: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (existsSync(join(editorDirectory(), name))) return;
    if (!session?.isAlive()) throw new Error(`fx exited before editor handshake ${name}`);
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for editor handshake ${name}`);
}

async function editorCapture(number = 1): Promise<EditorCapture> {
  await waitForEditorFile(`capture-${number}.json`);
  return JSON.parse(readFileSync(join(editorDirectory(), `capture-${number}.json`), "utf8"));
}

function documentPrompt(document: string): { nonce: string; prompt: string; reference: string } {
  const begin = [...document.matchAll(/^<!-- fx:prompt:begin:([0-9a-f]{32}) -->$/gm)];
  expect(begin).toHaveLength(1);
  const nonce = begin[0]![1]!;
  const end = `<!-- fx:prompt:end:${nonce} -->`;
  expect(document.split(end)).toHaveLength(2);
  const start = begin[0]!.index! + begin[0]![0].length + 1;
  const endIndex = document.indexOf(end);
  expect(endIndex).toBeGreaterThan(start);
  return { nonce, prompt: document.slice(start, endIndex - 1), reference: document.slice(endIndex + end.length) };
}

function expectEditorReaped(capture: EditorCapture): void {
  let alive = true;
  try { process.kill(capture.pid, 0); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
    alive = false;
  }
  expect(alive).toBe(false);
}

function expectPrivateEditor(capture: EditorCapture): void {
  expect(isAbsolute(capture.path)).toBe(true);
  expect(dirname(capture.path)).toBe(capture.cwd);
  expect(capture.cwd.startsWith(join(root!, "workspace"))).toBe(false);
  expect(capture.directoryMode).toBe(0o700);
  expect(capture.fileMode).toBe(0o600);
  expect(capture.argv).toEqual([EDITOR_ARGUMENT, capture.path]);
  expect(capture.stdinTty).toBe(true);
  expect(capture.stdoutTty).toBe(true);
  expect(capture.canonical).toBe(true);
  expect(capture.echo).toBe(true);
  expect(capture.signals).toBe(true);
  expect(capture.shellSideEffect).toBe(false);
}

async function expectPreservedEdit(active: TmuxSession, invocation: string, count = 0): Promise<void> {
  const capturePath = join(editorDirectory(), "capture-1.json");
  if (existsSync(capturePath)) {
    const capture = JSON.parse(readFileSync(capturePath, "utf8")) as EditorCapture;
    const deadline = Date.now() + TIMEOUT;
    while (existsSync(capture.cwd)) {
      if (!active.isAlive()) throw new Error("fx exited before editor scratch cleanup");
      if (Date.now() >= deadline) throw new Error("Editor scratch was not removed after cancellation");
      await Bun.sleep(25);
    }
    expectEditorReaped(capture);
  }
  // Require both the restored composer and a product notice, not the old
  // invocation or the editor's READY output left in terminal scrollback.
  await active.waitForPane((pane) => composerContains(pane, invocation) && pane.split("\n").some((line) =>
    !composerContains(line, invocation) && !line.includes("FX_EDITOR_") && /editor|VISUAL|EDITOR|edit:/i.test(line)
  ), TIMEOUT);
  await active.waitForStableScrollback((pane) => composerContains(pane, invocation), TIMEOUT);
  expect(gateway!.requestCount()).toBe(count);
  expectCleanRuntime(active);
}

async function ordinaryPromptAfterEdit(active: TmuxSession, prompt: string, count = 1): Promise<void> {
  await active.sendKeys("C-u");
  await active.sendText(prompt);
  await waitForCompletedTurn(active, count);
  expect(finalUserText(count - 1)).toBe(prompt);
  expect(gateway!.requestCount()).toBe(count);
  expectCleanRuntime(active);
}

async function quitCleanEditorRuntime(active: TmuxSession): Promise<void> {
  await active.sendText("/quit");
  await active.waitForSessionEnd(TIMEOUT);
  expect(active.recordedExitStatus()).toBe(0);
  expect(readFileSync(stderrPath!, "utf8")).toBe("");
}

tmuxTest("external /edit submits Unicode once and ignores edited reference history", async () => {
  const edited = "  Unicode café 日本語\n\n```markdown\n# Conversation history\n```\ntrailing space  \n";
  const active = await startFx(true, 5, false, undefined, scriptedEditor({ prompt: edited, mutateHistory: true }));
  for (const [index, prompt] of ["ARCHIVE_FIRST_OPENING", "ARCHIVE_SECOND_OPENING"].entries()) {
    await active.sendText(prompt);
    await waitForCompletedTurn(active, index + 1);
  }
  await active.sendText("/edit optional seed");
  await waitForCompletedTurn(active, 3);
  const first = await editorCapture();
  expectPrivateEditor(first);
  const exported = documentPrompt(first.document);
  expect(exported.prompt).toBe("optional seed");
  const history = ["ARCHIVE_FIRST_OPENING", "edit contract complete 1", "ARCHIVE_SECOND_OPENING", "edit contract complete 2"];
  const offsets = history.map((text) => exported.reference.indexOf(text));
  expect(offsets.every((offset) => offset >= 0)).toBe(true);
  expect(offsets).toEqual([...offsets].sort((a, b) => a - b));
  expect(finalUserText(2)).toBe(edited);
  expect(gatewayPromptText(2)).not.toContain("REFERENCE_WAS_REWRITTEN");
  expect(gatewayPromptText(2)).not.toContain("/edit optional seed");
  expect(existsSync(first.cwd)).toBe(false);
  expectEditorReaped(first);

  setEditorPlan({ prompt: "BLANK_SEED_EDITED" });
  await active.sendText("/edit");
  await waitForCompletedTurn(active, 4);
  const second = await editorCapture(2);
  const secondDocument = documentPrompt(second.document);
  expect(secondDocument.prompt).toBe("");
  expect(secondDocument.nonce).not.toBe(exported.nonce);
  expect(secondDocument.reference).toContain("ARCHIVE_FIRST_OPENING");
  expect(secondDocument.reference).toContain("ARCHIVE_SECOND_OPENING");
  expect(secondDocument.reference).toContain(edited);
  expect(secondDocument.reference).not.toContain("REFERENCE_WAS_REWRITTEN");
  expect(finalUserText(3)).toBe("BLANK_SEED_EDITED");
  expect(existsSync(second.cwd)).toBe(false);
  await ordinaryPromptAfterEdit(active, "ORDINARY_AFTER_EDIT", 5);
  const saved = await savedSession(isolatedHome!, onlySessionId(isolatedHome!));
  expect(JSON.stringify(saved.history)).toContain("ARCHIVE_FIRST_OPENING");
  expect(JSON.stringify(saved.history)).not.toContain("REFERENCE_WAS_REWRITTEN");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

for (const action of ["empty", "missing-end", "malformed-begin", "duplicate-begin", "nonzero", "signal"] as const) {
  tmuxTest(`external /edit ${action} preserves invocation and sends nothing`, async () => {
    const active = await startFx(true, 1, false, undefined, scriptedEditor({ action, prompt: "MUST_NOT_SUBMIT" }));
    const invocation = `/edit RETAIN_${action}`;
    await active.sendText(invocation);
    const capture = await editorCapture();
    await expectPreservedEdit(active, invocation);
    expect(existsSync(capture.cwd)).toBe(false);
    await ordinaryPromptAfterEdit(active, `RECOVERED_${action}`);
    await quitCleanEditorRuntime(active);
  }, TIMEOUT);
}

for (const [name, env] of [
  ["missing configuration", { VISUAL: undefined, EDITOR: undefined }],
  ["missing executable", { VISUAL: "/no-such-fx-selected-editor", EDITOR: "/bin/true" }],
  ["malformed selected command", { VISUAL: "\"unterminated", EDITOR: "/bin/true" }],
  ["shell operator", { VISUAL: "/bin/true | /bin/true", EDITOR: "/bin/true" }],
] as const) {
  tmuxTest(`external /edit ${name} is local and preserves invocation`, async () => {
    const active = await startFx(true, 1, false, undefined, { ...env });
    const invocation = "/edit RETAIN_CONFIGURATION";
    await active.sendText(invocation);
    await active.waitForText(/editor|VISUAL|EDITOR/i, TIMEOUT);
    await expectPreservedEdit(active, invocation);
    await ordinaryPromptAfterEdit(active, "RECOVERED_CONFIGURATION");
    await quitCleanEditorRuntime(active);
  }, TIMEOUT);
}

tmuxTest("external /edit accepts unchanged pasted seed and atomic replacement saves", async () => {
  const active = await startFx(true, 2, false, undefined, scriptedEditor());
  const seed = `PASTED_SEED_${"x".repeat(1200)}\nUnicode λ`;
  await pasteExact(active, `/edit ${seed}`);
  await active.sendKeys("Enter");
  await waitForCompletedTurn(active, 1);
  const first = await editorCapture();
  expect(documentPrompt(first.document).prompt).toBe(seed);
  expect(finalUserText()).toBe(seed);
  expect(existsSync(first.cwd)).toBe(false);
  setEditorPlan({ action: "atomic", prompt: "ATOMIC_SAVE_雪\r\nsecond line\rthird line" });
  await active.sendText("/edit atomic seed");
  await waitForCompletedTurn(active, 2);
  expect(finalUserText(1)).toBe("ATOMIC_SAVE_雪\nsecond line\nthird line");
  expect(gateway!.requestCount()).toBe(2);
  expect(existsSync((await editorCapture(2)).cwd)).toBe(false);
  expectCleanRuntime(active);
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit saved leading /reset is literal and retains prior conversation", async () => {
  const active = await startFx(true, 3, false, undefined, scriptedEditor({ prompt: "/reset\nLITERAL_RESET_BODY" }));
  await active.sendText("BEFORE_LITERAL_RESET");
  await waitForCompletedTurn(active, 1);
  const id = onlySessionId(isolatedHome!);
  await active.sendText("/edit");
  await waitForCompletedTurn(active, 2);
  expect(finalUserText(1)).toBe("/reset\nLITERAL_RESET_BODY");
  expect(gatewayPromptText(1)).toContain("BEFORE_LITERAL_RESET");
  expect(onlySessionId(isolatedHome!)).toBe(id);
  await ordinaryPromptAfterEdit(active, "AFTER_LITERAL_RESET", 3);
  expect(gatewayPromptText(2)).toContain("BEFORE_LITERAL_RESET");
  expect(gatewayPromptText(2)).toContain("LITERAL_RESET_BODY");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit Ctrl+C interrupts cooked editor and restores composer", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ interactive: true, prompt: "INTERRUPTED_MUST_NOT_SUBMIT" }));
  const invocation = "/edit KEEP_AFTER_INTERRUPT";
  await active.sendText(invocation);
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  expectPrivateEditor(capture);
  await active.sendKeys("C-c");
  await expectPreservedEdit(active, invocation);
  expect(existsSync(capture.cwd)).toBe(false);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_EDITOR_INTERRUPT");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit resize keeps cooked input and redraws restored composer", async () => {
  const active = await startFx(true, 2, false, undefined, scriptedEditor({ interactive: true, prompt: "SAVED_AFTER_RESIZE" }));
  await active.sendText("/edit resize seed");
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  expectPrivateEditor(capture);
  await active.resizeWindow(83, 27);
  await active.sendText("COOKED_LINE_雪");
  await active.waitForText("FX_EDITOR_INPUT_1", TIMEOUT);
  await waitForEditorFile("input-1.json");
  const input = JSON.parse(readFileSync(join(editorDirectory(), "input-1.json"), "utf8"));
  expect(input).toEqual({ text: "COOKED_LINE_雪", size: [83, 27] });
  await active.sendText("finish editor");
  await waitForCompletedTurn(active, 1);
  expect(finalUserText()).toBe("SAVED_AFTER_RESIZE");
  expect(existsSync(capture.cwd)).toBe(false);
  await active.resizeWindow(112, 32);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_EDITOR_RESIZE", 2);
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit discards coalesced command suffix with visible notice", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ action: "empty", hold: true }));
  // One small write puts the suffix in the same input delivery as Enter.
  await active.sendHexBytes(textHex("/edit KEEP_AFTER_SUFFIX\r/reset\rUNEXPECTED_SUFFIX\r"));
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  writeFileSync(join(editorDirectory(), "release"), "release");
  await active.waitForText(/input[^\n]*(ignored|discarded)/i, TIMEOUT);
  await expectPreservedEdit(active, "/edit KEEP_AFTER_SUFFIX");
  expect(gateway!.requestCount()).toBe(0);
  expect(composerContains(await active.capturePane(), "UNEXPECTED_SUFFIX")).toBe(false);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_DISCARDED_SUFFIX");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

for (const entity of ["image", "skill"] as const) {
  tmuxTest(`external /edit refuses registered ${entity} without discarding it`, async () => {
    const active = await startFx(true, 1, false, undefined, scriptedEditor({ prompt: "REFUSAL_MUST_NOT_LAUNCH" }));
    if (entity === "image") {
      await pasteExact(active, fixtureImagePath!);
      await active.waitForText("[Image 1]", TIMEOUT);
    } else {
      await selectReviewSkill(active);
    }
    await active.sendLiteralText("REFUSAL_ENTITY_BODY");
    await active.sendKeys("Home");
    await active.sendLiteralText("/edit ");
    await active.sendKeys("Enter");
    await active.waitForText(/(image|skill|attachment)[^\n]*(remove|edit|support)|edit[^\n]*(image|skill|attachment)/i, TIMEOUT);
    await expectPreservedEdit(active, "/edit");
    expect(existsSync(join(editorDirectory(), "capture-1.json"))).toBe(false);
    // Remove just the command prefix, then prove the entity still submits.
    await active.sendKeys("Home");
    for (let i = 0; i < "/edit ".length; i += 1) await active.sendKeys("DC");
    await active.sendKeys("Enter");
    await waitForCompletedTurn(active, 1);
    expect(finalUserText()).toContain("REFUSAL_ENTITY_BODY");
    if (entity === "image") expect(userParts().filter((part) => part.type === "file")).toHaveLength(1);
    else expect(gatewayPromptText()).toContain(MANAGED_REVIEW_BODY);
    expectCleanRuntime(active);
    await quitCleanEditorRuntime(active);
  }, TIMEOUT);
}

tmuxTest("external /edit exports and submits only the second visible instance", async () => {
  const active = await startFx(true, 4, false, undefined, scriptedEditor({ prompt: "SECOND_INSTANCE_EDITED" }));
  await active.sendText("FIRST_INSTANCE_ARCHIVE");
  await waitForCompletedTurn(active, 1);
  await active.sendText("/launch");
  await active.waitForText("fx 2/2", TIMEOUT);
  await active.waitForComposer(TIMEOUT);
  await active.sendText("SECOND_INSTANCE_ARCHIVE");
  await waitForCompletedTurn(active, 2);
  await active.sendText("/edit second seed");
  await waitForCompletedTurn(active, 3);
  const reference = documentPrompt((await editorCapture()).document).reference;
  expect(reference).toContain("SECOND_INSTANCE_ARCHIVE");
  expect(reference).not.toContain("FIRST_INSTANCE_ARCHIVE");
  expect(finalUserText(2)).toBe("SECOND_INSTANCE_EDITED");
  expect(gatewayPromptText(2)).not.toContain("FIRST_INSTANCE_ARCHIVE");
  await ordinaryPromptAfterEdit(active, "SECOND_INSTANCE_ORDINARY", 4);
  expect(gatewayPromptText(3)).toContain("SECOND_INSTANCE_EDITED");
  expect(gatewayPromptText(3)).not.toContain("FIRST_INSTANCE_ARCHIVE");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit refuses busy host without launching editor or queueing a prompt", async () => {
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  const active = await startFx(true, 2, false, undefined, scriptedEditor(), [
    async () => { await held; return fakeGatewayFinalText("edit contract complete 1"); },
    fakeGatewayFinalText("edit contract complete 2"),
  ]);
  try {
    await active.sendText("BUSY_ORIGINAL_REQUEST");
    await waitForGatewayRequest();
    await active.waitForText(/Thinking|esc.*interrupt/i, TIMEOUT);
    await active.sendText("/edit KEEP_WHILE_BUSY");
    await active.waitForText(/edit[^\n]*(busy|work|idle|finish|running)|(?:busy|work|idle|finish|running)[^\n]*edit/i, TIMEOUT);
    await expectPreservedEdit(active, "/edit KEEP_WHILE_BUSY", 1);
    expect(existsSync(join(editorDirectory(), "capture-1.json"))).toBe(false);
    release();
    await active.waitForPane((pane) => pane.includes("edit contract complete 1") && composerContains(pane, "KEEP_WHILE_BUSY") && !pane.includes("Thinking"), TIMEOUT);
    await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_BUSY_REFUSAL", 2);
    expect(gatewayPromptText(1)).not.toContain("KEEP_WHILE_BUSY");
    await quitCleanEditorRuntime(active);
  } finally {
    release();
  }
}, TIMEOUT);

tmuxTest("external /edit exports original archive after compaction and resume", async () => {
  const early = "ARCHIVE_BEFORE_COMPACTION: release region is ap-southeast-2. Briefly acknowledge receipt only.";
  let active = await startFx(true, 5, false, undefined, scriptedEditor({ prompt: "EDIT_AFTER_COMPACTED_RESUME" }), [
    fakeGatewayFinalText("edit contract complete 1"),
    fakeGatewayFinalText("edit contract complete 2"),
    fakeGatewayFinalText("edit contract complete 3"),
    fakeGatewayFinalText(`Rules:\n- R1 (M1): "${early}"`),
    fakeGatewayFinalText("edit contract complete 5"),
  ]);
  for (const [index, prompt] of [early, "ARCHIVE_MIDDLE_BEFORE_COMPACTION", "ARCHIVE_LATEST_BEFORE_COMPACTION"].entries()) {
    await active.sendText(prompt);
    await waitForCompletedTurn(active, index + 1);
  }
  const id = onlySessionId(isolatedHome!);
  const logPath = join(sessionDir(isolatedHome!, id), "log.jsonl");
  await active.sendText("/compact");
  const deadline = Date.now() + TIMEOUT;
  while (!readFileSync(logPath, "utf8").includes('"kind":"compacted"')) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for durable compaction before editor export");
    await Bun.sleep(25);
  }
  expect(logLines(isolatedHome!, id).filter((line) => line.kind === "compacted")).toHaveLength(1);
  await active.waitForPane((pane) => hasEmptyComposer(pane) && !/Preparing compaction|Compacting|Stopping compaction/.test(pane), TIMEOUT);
  await quitCleanEditorRuntime(active);
  await active.kill();
  const launcher = join(editorDirectory(), "editor with spaces.sh");
  session = active = await TmuxSession.create({
    cmd: `${JSON.stringify(FX_BIN)} --resume ${JSON.stringify(id)}`,
    cwd: join(root!, "workspace"),
    env: {
      HOME: isolatedHome!, AI_GATEWAY_API_KEY: "fake-edit-contract-key", VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway!.baseUrl, FX_GATEWAY_CHAT_URL: gateway!.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway!.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL, FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
      VISUAL: `${JSON.stringify(launcher)} ${JSON.stringify(EDITOR_ARGUMENT)}`,
      EDITOR: "/no-such-fx-fallback-editor",
    },
    width: 112, height: 32, stderrPath: stderrPath!,
  });
  await active.waitForComposer(TIMEOUT);
  await active.sendText("/edit");
  await waitForCompletedTurn(active, 5);
  const reference = documentPrompt((await editorCapture()).document).reference;
  const originals = [early, "edit contract complete 1", "ARCHIVE_MIDDLE_BEFORE_COMPACTION", "edit contract complete 2", "ARCHIVE_LATEST_BEFORE_COMPACTION", "edit contract complete 3"];
  const offsets = originals.map((text) => reference.indexOf(text));
  expect(offsets.every((offset) => offset >= 0)).toBe(true);
  expect(offsets).toEqual([...offsets].sort((a, b) => a - b));
  for (const original of originals) expect(reference.split(original)).toHaveLength(2);
  expect(reference).not.toContain("fx-compactor-v1");
  expect(finalUserText(4)).toBe("EDIT_AFTER_COMPACTED_RESUME");
  expect(gateway!.requestCount()).toBe(5);
  expectCleanRuntime(active);
  await quitCleanEditorRuntime(active);
}, TIMEOUT);

tmuxTest("external /edit blank VISUAL selects EDITOR and editfoo is not the command", async () => {
  const configured = scriptedEditor({ prompt: "EDITOR_FALLBACK_PROMPT" });
  const active = await startFx(true, 2, false, undefined, (fixtureRoot) => {
    const env = configured(fixtureRoot);
    return { VISUAL: " \t ", EDITOR: env.VISUAL! };
  });
  await active.sendText("/editfoo literal boundary");
  await waitForCompletedTurn(active, 1);
  expect(finalUserText(0)).toBe("/editfoo literal boundary");
  expect(existsSync(join(editorDirectory(), "capture-1.json"))).toBe(false);
  // Unknown slash handling is not this contract; remove a retained unknown
  // invocation, if any, before exercising the editor fallback.
  await active.sendKeys("C-u");
  const before = gateway!.requestCount();
  await active.sendText("/edit");
  await waitForCompletedTurn(active, before + 1);
  expect(finalUserText(before)).toBe("EDITOR_FALLBACK_PROMPT");
  expectPrivateEditor(await editorCapture());
  expect(gateway!.requestCount()).toBe(before + 1);
  await quitCleanEditorRuntime(active);
}, TIMEOUT);


for (const action of ["symlink", "hardlink", "fifo", "nul", "utf8", "oversize"] as const) {
  tmuxTest(`external /edit rejects ${action} saved document and preserves invocation`, async () => {
    const active = await startFx(true, 1, false, undefined, scriptedEditor({ action }));
    const invocation = `/edit RETAIN_UNSAFE_${action}`;
    await active.sendText(invocation);
    await expectPreservedEdit(active, invocation);
    await ordinaryPromptAfterEdit(active, `NORMAL_AFTER_${action}`);
    await quitCleanEditorRuntime(active);
  }, TIMEOUT);
}

tmuxTest("external /edit waits for an interrupted wrapper and surviving editor before restoring fx", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ wrapper: true, surviveInterrupt: true, interactive: true }));
  const invocation = "/edit RETAIN_AFTER_WRAPPER_INTERRUPT";
  await active.sendText(invocation);
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  await active.sendKeys("C-c");
  // The editor deliberately handles SIGINT. Its next visible input handshake
  // proves fx has not killed the wrapper and reclaimed its TTY prematurely.
  await active.sendText("EDITOR_STILL_OWNS_TTY");
  await active.waitForText("FX_EDITOR_INPUT_1", TIMEOUT);
  const input = JSON.parse(readFileSync(join(editorDirectory(), "input-1.json"), "utf8"));
  expect(input.text).toBe("EDITOR_STILL_OWNS_TTY");
  expect(existsSync(capture.cwd)).toBe(true);
  expect(gateway!.requestCount()).toBe(0);
  await active.sendText("close editor");
  await expectPreservedEdit(active, invocation);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_WRAPPER_INTERRUPT");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);


tmuxTest("external /edit shared foreground job stops and resumes without cancelling the editor", async () => {
  const active = await startFx(true, 2, false, undefined, scriptedEditor({ interactive: true, prompt: "SAVED_AFTER_JOB_CONTINUE" }), undefined, true);
  await active.sendText("/edit job seed");
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  await active.sendKeys("C-z");
  await active.waitForPane((pane) => /Stopped/.test(pane) && pane.includes("FX_EDIT_JOB_SHELL_PROMPT>"), TIMEOUT);
  expect(existsSync(capture.cwd)).toBe(true);
  expect(gateway!.requestCount()).toBe(0);
  await active.sendText("fg");
  await active.sendText("COOKED_AFTER_JOB_CONTINUE");
  await active.waitForText("FX_EDITOR_INPUT_1", TIMEOUT);
  const input = JSON.parse(readFileSync(join(editorDirectory(), "input-1.json"), "utf8"));
  expect(input.text).toBe("COOKED_AFTER_JOB_CONTINUE");
  await active.sendText("finish editor");
  await waitForCompletedTurn(active, 1);
  expect(finalUserText()).toBe("SAVED_AFTER_JOB_CONTINUE");
  expectEditorReaped(capture);
  expect(existsSync(capture.cwd)).toBe(false);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_JOB_CONTINUE", 2);
  await active.sendText("/quit");
  await active.waitForText("FX_EDIT_JOB_SHELL_PROMPT>", TIMEOUT);
  await active.sendText(`printf 'FX_JOB_EXIT:%s\\n' "$?"`);
  await active.waitForText("FX_JOB_EXIT:0", TIMEOUT);
  expect(readFileSync(stderrPath!, "utf8")).toBe("");
  await active.sendText("exit");
  await active.waitForSessionEnd(TIMEOUT);
  expect(active.recordedExitStatus()).toBe(0);
}, TIMEOUT);

tmuxTest("external /edit independently stopped editor resumes for cleanup and cancels submission", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ interactive: true }));
  const invocation = "/edit KEEP_AFTER_CHILD_STOP";
  await active.sendText(invocation);
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  process.kill(capture.pid, "SIGSTOP");
  await active.sendText("EDITOR_RESUMED_FOR_CLEANUP");
  await active.waitForText("FX_EDITOR_INPUT_1", TIMEOUT);
  expect(existsSync(capture.cwd)).toBe(true);
  await active.sendText("close editor");
  await expectPreservedEdit(active, invocation);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_CHILD_STOP");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);


tmuxTest("external /edit an immediate restop after foreground continue cannot strand fx", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ interactive: true, restopAfterContinue: true }), undefined, true);
  const invocation = "/edit KEEP_AFTER_RESTOP";
  await active.sendText(invocation);
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  await active.sendKeys("C-z");
  await active.waitForPane((pane) => /Stopped/.test(pane) && pane.includes("FX_EDIT_JOB_SHELL_PROMPT>"), TIMEOUT);
  await active.sendText("fg");
  await active.sendText("EDITOR_ALIVE_AFTER_RESTOP");
  await active.waitForText("FX_EDITOR_INPUT_1", TIMEOUT);
  await active.sendText("close editor");
  await expectPreservedEdit(active, invocation);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_RESTOP");
  await active.sendText("/quit");
  await active.waitForText("FX_EDIT_JOB_SHELL_PROMPT>", TIMEOUT);
  expect(readFileSync(stderrPath!, "utf8")).toBe("");
  await active.sendText("exit");
  await active.waitForSessionEnd(TIMEOUT);
  expect(active.recordedExitStatus()).toBe(0);
}, TIMEOUT);


tmuxTest("external /edit Ctrl+C resumes a stopped editor behind its waiting wrapper", async () => {
  const active = await startFx(true, 1, false, undefined, scriptedEditor({ wrapper: true, interactive: true }));
  const invocation = "/edit KEEP_AFTER_WRAPPED_STOP";
  await active.sendText(invocation);
  await active.waitForText("FX_EDITOR_READY_1", TIMEOUT);
  const capture = await editorCapture();
  process.kill(capture.pid, "SIGSTOP");
  await active.sendKeys("C-c");
  await expectPreservedEdit(active, invocation);
  await ordinaryPromptAfterEdit(active, "NORMAL_AFTER_WRAPPED_STOP");
  await quitCleanEditorRuntime(active);
}, TIMEOUT);
