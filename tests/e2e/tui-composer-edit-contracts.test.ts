import { afterEach, expect, test } from "bun:test";
import {
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
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
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
const MANAGED_REVIEW_BODY = "GROUP_C_MANAGED_REVIEW_BODY";
const WORKSPACE_REVIEW_BODY = "GROUP_C_WORKSPACE_REVIEW_BODY";

let session: TmuxSession | null = null;
let root: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let fixtureImagePath: string | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
  stderrPath = null;
  fixtureImagePath = null;
});

async function startFx(
  withGateway: boolean,
  responseCount = 1,
  duplicateReview = false,
  traceScopes?: string,
): Promise<TmuxSession> {
  root = realpathSync(mkdtempSync(join(tmpdir(), "fx-edit-contracts-")));
  const home = join(root, "home");
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
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
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
      Array.from(
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
    cmd: FX_BIN,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: withGateway ? "fake-edit-contract-key" : undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway?.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway?.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: gateway
        ? `${gateway.baseUrl}/coding-agent/v1/models`
        : undefined,
      FX_MODEL: withGateway ? FAKE_GATEWAY_MODEL : undefined,
      FX_AUTO_UPGRADE: "0",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: traceScopes,
    },
    width: 112,
    height: 32,
    stderrPath,
  });
  await session.waitForComposer(TIMEOUT);
  return session;
}

function historyImageSnapshotPath(): string {
  const sessionsRoot = join(root!, "home", ".fx", "sessions");
  const sessionNames = readdirSync(sessionsRoot, { withFileTypes: true })
    .filter((entry) =>
      entry.isDirectory() &&
      existsSync(join(sessionsRoot, entry.name, "images"))
    )
    .map((entry) => entry.name);
  expect(sessionNames).toHaveLength(1);
  const imageDir = join(sessionsRoot, sessionNames[0]!, "images");
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

function finalUserText(requestIndex = 0): string {
  return userParts(requestIndex).find((part) => part.type === "text")?.text ??
    "";
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

async function selectReviewSkill(
  active: TmuxSession,
  selectWorkspace = false,
): Promise<void> {
  await active.sendLiteralText("$review");
  await active.waitForText("Enter Use", TIMEOUT);
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
    await waitForTraceOrExit(active, "reason=unsafe_suffix");

    expect(gateway?.requestCount()).toBe(0);
    expect(await active.captureFullScrollback()).not.toContain("● Version:");
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
    await waitForTraceOrExit(active, "reason=unsafe_suffix");

    expect(gateway?.requestCount()).toBe(0);
    await active.waitForText("ESCAPE_DRAFT", TIMEOUT);
    await active.sendKeys("Enter");
    await waitForGatewayRequest();
    expect(finalUserText()).toBe("ESCAPE_DRAFT");
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
    expectCleanRuntime(active);
  },
  TIMEOUT,
);

for (
  const scenario of [
    {
      name: "corrupt",
      expectedError: "ImageSnapshotCorrupt",
      damage(path: string) {
        writeFileSync(path, Buffer.from("corrupt history snapshot"));
      },
    },
    {
      name: "deleted",
      expectedError: "FileNotFound",
      damage(path: string) {
        rmSync(path, { force: true });
      },
    },
  ]
) {
  tmuxTest(
    `history recall preserves the composer when an image snapshot is ${scenario.name}`,
    async () => {
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

      scenario.damage(historyImageSnapshotPath());
      await active.sendLiteralText("KEEP_CURRENT_DRAFT");
      await active.sendKeys("Up");
      await active.sendKeys("Up");
      const rejectionTrace =
        `[prompt_history] event=recall_rejected err=${scenario.expectedError}`;
      await waitForTraceOrExit(active, rejectionTrace);

      expect(active.isAlive()).toBe(true);
      await active.waitForText("KEEP_CURRENT_DRAFT", TIMEOUT);
      expect(readFileSync(stderrPath!, "utf8")).toBe("");
      expect(readFileSync(join(root!, "trace.log"), "utf8")).toContain(rejectionTrace);
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
