import { expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  startUpgradeServer,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MAIN_MODEL = "openai/gpt-5.5";
const TITLE_MODEL = "openai/gpt-5.6-luna";
const GENERATED_TITLE = "Renderer Loop Refactor";

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
};

function createFixtureRoot(label: string, settings: string = "{}"): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-session-title-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), settings);
  return { root, home, workspace: realpathSync(workspace) };
}

function startTitleAwareGateway() {
  return startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [fakeGatewayFinalText(GENERATED_TITLE)],
  });
}

function baseEnv(root: FixtureRoot, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: root.home,
    AI_GATEWAY_API_KEY: "synthetic-title",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: MAIN_MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function sessionTitles(root: FixtureRoot): string[] {
  const sessionsDir = join(root.home, ".fx", "sessions");
  if (!existsSync(sessionsDir)) return [];
  const titles: string[] = [];
  for (const id of readdirSync(sessionsDir)) {
    const manifest = join(sessionsDir, id, "session.json");
    if (!existsSync(manifest)) continue;
    const value = JSON.parse(readFileSync(manifest, "utf8"));
    if (typeof value.title === "string") titles.push(value.title);
  }
  return titles;
}

function titleRequests(gateway: ReturnType<typeof startTitleAwareGateway>) {
  return gateway.titleRequests;
}

test("fx ask generates a model title for a fresh session", async () => {
  const root = createFixtureRoot("ask");
  const gateway = startTitleAwareGateway();
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");

    const titleCalls = titleRequests(gateway);
    expect(titleCalls.length).toBe(1);
    expect(titleCalls[0].headers.get("ai-language-model-id")).toBe(TITLE_MODEL);
    expect(titleCalls[0].body).toContain("refactor the renderer loop");

    expect(sessionTitles(root)).toContain(GENERATED_TITLE);

    const list = await runFx(["sessions", "--json"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 15_000,
    });
    expect(list.code).toBe(0);
    expect(list.stdout).toContain(GENERATED_TITLE);
  } finally {
    gateway.stop();
  }
});

test("fx ask keeps the derived title when session_titles is off", async () => {
  const root = createFixtureRoot("disabled", JSON.stringify({ session_titles: false }));
  const gateway = startTitleAwareGateway();
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    expect(titleRequests(gateway).length).toBe(0);
    expect(sessionTitles(root)).not.toContain(GENERATED_TITLE);
  } finally {
    gateway.stop();
  }
});

test("fx ask keeps the derived title when the title model output is unusable", async () => {
  const root = createFixtureRoot("unusable");
  const gateway = startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [fakeGatewayFinalText("\n  \n")],
  });
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    const titles = sessionTitles(root);
    expect(titles.length).toBe(1);
    expect(titles[0]).not.toBe(GENERATED_TITLE);
    expect(titles[0].length).toBeGreaterThan(0);
  } finally {
    gateway.stop();
  }
});

const SKIP_TMUX = !tmuxAvailable();

function traceTmpDir(root: FixtureRoot): string {
  const dir = join(root.root, "tmp");
  mkdirSync(dir, { recursive: true });
  return dir;
}

function traceReports(root: FixtureRoot): string[] {
  return readdirSync(traceTmpDir(root))
    .filter(name => name.startsWith("fx-trace-") && name.endsWith(".md"))
    .sort();
}

async function captureTraceReport(tui: TmuxSession, root: FixtureRoot): Promise<string> {
  const before = new Set(traceReports(root));
  await tui.sendText("/trace");
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const fresh = traceReports(root).filter(name => !before.has(name));
    if (fresh.length > 0) {
      // The filename becomes visible between create and the content write, so
      // wait for the report's closing section before reading.
      const path = join(traceTmpDir(root), fresh[fresh.length - 1]);
      const content = readFileSync(path, "utf8");
      if (content.includes("## Transcript Timeline")) return content;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("trace report was not written");
}

test.skipIf(SKIP_TMUX)("tui trace report shows an installed session title", async () => {
  const root = createFixtureRoot("tui-trace", JSON.stringify({ statusLine: { session: true } }));
  const gateway = startTitleAwareGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...baseEnv(root, gateway), TMPDIR: traceTmpDir(root) },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);

    const report = await captureTraceReport(tui, root);
    expect(report).toContain("## Session Title");
    expect(report).toContain("setting: true");
    expect(report).toContain(`title: ${GENERATED_TITLE}`);
    expect(report).toContain("generation: status=installed");
    expect(report).toContain(`model=${TITLE_MODEL}`);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui trace report explains why no session title was generated", async () => {
  const root = createFixtureRoot("tui-trace-failed");
  const gateway = startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [fakeGatewayFinalText("\n  \n")],
  });
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...baseEnv(root, gateway), TMPDIR: traceTmpDir(root) },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);

    // The title task finishes right after the fake gateway responds, but there
    // is no visible signal for a failed title, so retry while it is running.
    const deadline = Date.now() + 20_000;
    let report = "";
    while (Date.now() < deadline) {
      report = await captureTraceReport(tui, root);
      if (!report.includes("generation: status=running")) break;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    expect(report).toContain("## Session Title");
    expect(report).toContain("generation: status=failed");
    expect(report).toContain("model=openai/gpt-5.6-luna");
    expect(report).toContain("reason=unsanitizable");
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui shows the generated session title", async () => {
  const root = createFixtureRoot("tui", JSON.stringify({ statusLine: { session: true } }));
  const gateway = startTitleAwareGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: baseEnv(root, gateway),
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui generates a title after an upgrade relaunch resumes an untitled session", async () => {
  const root = createFixtureRoot("tui-upgrade-title", JSON.stringify({ statusLine: { session: true } }));
  const installDir = join(root.root, "install");
  mkdirSync(installDir);
  const installedFx = join(installDir, "fx");
  copyFileSync(FX_BIN, installedFx);
  chmodSync(installedFx, 0o755);
  const argvLogPath = join(root.root, "upgrade-argv.log");
  const release = startUpgradeServer(root.root, argvLogPath);
  const gateway = startTitleAwareGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(installedFx),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: {
        ...baseEnv(root, gateway),
        FX_AUTO_UPGRADE: "1",
        FX_E2E_UPGRADE_BASE_URL: release.baseUrl,
      },
    });
    await tui.waitForStableComposer(15000);
    // No prompt before the relaunch: the session stays pristine and untitled.
    await tui.waitForText("update ready: ctrl+g to reload", 60_000);
    await tui.sendHexBytes(["07"]);
    await tui.waitForStableComposer(15000);

    // Pin the resume leg: the relaunch must resume the same session, not start
    // a fresh one (a fresh session would title on the first prompt anyway).
    const sessionId = readdirSync(join(root.home, ".fx", "sessions"))
      .filter(name => name !== "latest")[0]!;
    const relaunchArgv = readFileSync(argvLogPath, "utf8").trim().split("\n");
    expect(relaunchArgv).toContain(`${installedFx}\tresume\t${sessionId}\t--upgrade-relaunch`);

    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
    expect(titleRequests(gateway).length).toBe(1);
  } finally {
    await tui?.kill();
    gateway.stop();
    release.stop();
  }
}, 120_000);
