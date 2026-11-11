import { expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { logLines, rootSessionIds, storeRoot } from "./saved-sessions";
import {
  bearer,
  rotateFxLogin,
  signInFxLoginToTeam,
  startFakeIssuer,
  storedFxLoginToken,
  unauthorized,
  writeFxLogin,
} from "./fx-login-fakes";
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
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: MAIN_MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

/// Each saved session's title: its log's newest title setting.
function sessionTitles(root: FixtureRoot): string[] {
  if (!existsSync(storeRoot(root.home))) return [];
  return rootSessionIds(root.home).flatMap((id) => {
    const title = (logLines(root.home, id) as any[]).filter((line) => line.kind === "set" && line.key === "title").at(-1)?.value;
    return typeof title === "string" ? [title] : [];
  });
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

test("fx ask exits soon after its answer while the title request never answers", async () => {
  const root = createFixtureRoot("title-hang");
  let titleArrived = false;
  const gateway = startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [() => {
      titleArrived = true;
      return new Promise<Response>(() => {});
    }],
  });
  try {
    const started = Date.now();
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    const elapsedMs = Date.now() - started;
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    expect(titleArrived).toBe(true);
    // The title call's own deadline is 15 s; fx gives it a short grace after
    // the answer and then leaves.
    expect(elapsedMs).toBeLessThan(8_000);

    // The session keeps the title derived from its first prompt.
    const titles = sessionTitles(root);
    expect(titles).toHaveLength(1);
    expect(titles[0]).toContain("refactor the renderer loop");
    const list = await runFx(["sessions", "--json"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 15_000,
    });
    expect(list.code).toBe(0);
    expect(list.stdout).toContain(titles[0]);
  } finally {
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 45_000);

test("fx ask keeps a generated title that arrives soon after its answer", async () => {
  const root = createFixtureRoot("title-late");
  const gateway = startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [() => Bun.sleep(1_000).then(() => fakeGatewayFinalText(GENERATED_TITLE))],
  });
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
  } finally {
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 45_000);

test("fx ask exits promptly on SIGINT while its title request never answers", async () => {
  const root = createFixtureRoot("interrupt");
  let chatArrived!: () => void;
  let titleArrived!: () => void;
  const chatRequest = new Promise<void>((resolve) => { chatArrived = resolve; });
  const titleRequest = new Promise<void>((resolve) => { titleArrived = resolve; });
  // Neither request ever gets response headers.
  const gateway = startDynamicFakeGateway(() => {
    chatArrived();
    return new Promise<Response>(() => {});
  }, {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [() => {
      titleArrived();
      return new Promise<Response>(() => {});
    }],
  });
  const child = Bun.spawn([FX_BIN, "ask", "refactor the renderer loop to fix the crash"], {
    cwd: root.workspace,
    env: baseEnv(root, gateway),
    stdout: "pipe",
    stderr: "pipe",
  });
  try {
    await Promise.all([chatRequest, titleRequest]);
    const signalledAt = Date.now();
    child.kill("SIGINT");
    // The title call's own deadline is 15 s, so an exit that waits for it
    // lands far past this bound.
    const code = await Promise.race([child.exited, Bun.sleep(8_000).then(() => null)]);
    expect(Date.now() - signalledAt).toBeLessThan(2_000);
    expect(code).toBe(130);
  } finally {
    if (child.exitCode === null) child.kill("SIGKILL");
    await child.exited;
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 30_000);

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

test.skipIf(SKIP_TMUX)("tui generates a title in the fresh session an upgrade relaunch opens for a session that saved nothing", async () => {
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
        FX_TEST_UPGRADE_BASE_URL: release.baseUrl,
      },
    });
    await tui.waitForStableComposer(15000);
    // No prompt before the relaunch: the session stays pristine and untitled.
    await tui.waitForText("update ready: ctrl+g to reload", 60_000);
    await tui.sendHexBytes(["07"]);
    await tui.waitForStableComposer(15000);

    // The relaunch hands over the session, which saved nothing without a
    // turn (D2), so the new build opens a fresh session with the update's
    // notice instead (D81).
    const handed = readFileSync(argvLogPath, "utf8").trim().split("\n")
      .map(line => line.split("\t"))
      .find(args => args[0] === installedFx && args[1] === "resume" && args[3] === "--upgrade-relaunch");
    expect(handed).toBeDefined();
    await tui.waitForText("fx has been updated to ", 15000);

    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
    expect(rootSessionIds(root.home)).not.toContain(handed![2]);
    expect(titleRequests(gateway).length).toBe(1);
  } finally {
    await tui?.kill();
    gateway.stop();
    release.stop();
  }
}, 120_000);

// Title requests made with a refreshable sign-in. Another fx process can
// refresh the shared fx login after this one has read it, so the token it holds
// in memory is rejected while the store already holds a newer one. The title
// request sends the stored token, and after a 401 sends once more only with a
// stored token that replaced the rejected one. It never refreshes the login
// itself (tests/tla/session_title/SessionTitle.tla BackgroundNeverRefreshes).

const FIRST_PROMPT = "refactor the renderer loop to fix the crash";

function loginEnv(root: FixtureRoot, gateway: { baseUrl: string; chatUrl: string }, issuer: { issuerUrl: string }) {
  return {
    ...baseEnv(root, gateway),
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl,
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_NO_OPEN_BROWSER: "1",
  };
}

/// A title channel that answers with the generated title only for `accepts`.
function titleFor(accepts: (token: string) => boolean) {
  return (_body: string, headers: Headers) =>
    accepts(bearer(headers)) ? fakeGatewayFinalText(GENERATED_TITLE) : unauthorized();
}

function titleTokens(gateway: ReturnType<typeof startDynamicFakeGateway>): string[] {
  return gateway.titleRequests.map((request) => bearer(request.headers));
}

function lastTitle(root: FixtureRoot): string | undefined {
  return sessionTitles(root).at(-1);
}

function startLoginGateway(titles: Array<(body: string, headers: Headers) => Response>) {
  return startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: titles,
  });
}

async function askWithLogin(label: string, titles: (home: string) => Array<(body: string, headers: Headers) => Response>) {
  const root = createFixtureRoot(label);
  const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
  writeFxLogin(root.home, issuer.issuerUrl, "launch-token");
  const gateway = startLoginGateway(titles(root.home));
  try {
    const result = await runFx(["ask", FIRST_PROMPT], { cwd: root.workspace, env: loginEnv(root, gateway, issuer), timeoutMs: 30_000 });
    expect(result.code, result.stderr).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    // A title request never refreshes the login all fx processes share.
    expect(issuer.refreshes).toHaveLength(0);
    return { tokens: titleTokens(gateway), title: lastTitle(root), stored: storedFxLoginToken(root.home) };
  } finally {
    gateway.stop();
    issuer.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}

test("fx ask keeps the derived title without refreshing the login when the gateway rejects the stored one", async () => {
  const rejected = titleFor(() => false);
  const run = await askWithLogin("login-401-stored", () => [rejected, rejected]);
  expect(run.tokens).toEqual(["launch-token"]);
  expect(run.stored).toBe("launch-token");
  expect(run.title).toContain("refactor the renderer loop");
}, 45_000);

test("fx ask sends a rejected title with the login another fx already renewed, without refreshing", async () => {
  const accept = titleFor((token) => token === "other-fx-token");
  // The first title request arrives after another fx renewed the login.
  const run = await askWithLogin("login-401-renewed-elsewhere", (home) => [(body, headers) => {
    rotateFxLogin(home, "other-fx-token");
    return accept(body, headers);
  }, accept, accept]);
  expect(run.tokens).toEqual(["launch-token", "other-fx-token"]);
  expect(run.title).toBe(GENERATED_TITLE);
}, 45_000);

test("fx ask sends the title at most twice while another fx keeps renewing the login", async () => {
  let renewals = 0;
  const run = await askWithLogin("login-401-always", (home) => Array.from({ length: 3 }, () => () => {
    renewals += 1;
    rotateFxLogin(home, `other-fx-token-${renewals}`);
    return unauthorized();
  }));
  expect(run.tokens).toEqual(["launch-token", "other-fx-token-1"]);
  expect(run.title).toContain("refactor the renderer loop");
}, 45_000);

test("fx ask never sends the title with the login another fx signed in to another team", async () => {
  const any = titleFor(() => true);
  const run = await askWithLogin("login-other-team", (home) => [() => {
    signInFxLoginToTeam(home, "other-team-token", "team_other");
    return unauthorized();
  }, any, any]);
  expect(run.tokens).toEqual(["launch-token"]);
  expect(run.stored).toBe("other-team-token");
  expect(run.title).toContain("refactor the renderer loop");
}, 45_000);

test("fx ask does not send the title again when the gateway refuses it with 403", async () => {
  const forbidden = () => Response.json({ error: { message: "Model not allowed", type: "permission_error" } }, { status: 403 });
  const run = await askWithLogin("login-403", (home) => [() => {
    rotateFxLogin(home, "other-fx-token");
    return forbidden();
  }, forbidden]);
  expect(run.tokens).toEqual(["launch-token"]);
}, 45_000);

test("fx ask sends a static key's rejected title once", async () => {
  const root = createFixtureRoot("static-key-401");
  const rejected = titleFor(() => false);
  const gateway = startLoginGateway([rejected, rejected]);
  try {
    const result = await runFx(["ask", FIRST_PROMPT], { cwd: root.workspace, env: baseEnv(root, gateway), timeoutMs: 30_000 });
    expect(result.code, result.stderr).toBe(0);
    expect(titleTokens(gateway)).toEqual(["synthetic-title"]);
    expect(lastTitle(root)).toContain("refactor the renderer loop");
  } finally {
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 45_000);

test.skipIf(SKIP_TMUX)("tui sends the title with the login another fx refreshed after launch", async () => {
  const root = createFixtureRoot("tui-stale-login", JSON.stringify({ statusLine: { session: true } }));
  const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
  writeFxLogin(root.home, issuer.issuerUrl, "launch-token");
  let accepted = "launch-token";
  const title = titleFor((token) => token === accepted);
  const gateway = startLoginGateway([title, title]);
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: loginEnv(root, gateway, issuer),
    });
    await tui.waitForStableComposer(15000);
    // Another fx refreshes the shared login, and the old token stops working.
    rotateFxLogin(root.home, "other-fx-token");
    accepted = "other-fx-token";
    await tui.sendText(FIRST_PROMPT);
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(titleTokens(gateway)).toEqual(["other-fx-token"]);
    expect(issuer.refreshes).toHaveLength(0);
    expect(lastTitle(root)).toBe(GENERATED_TITLE);
  } finally {
    await tui?.kill();
    gateway.stop();
    issuer.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui gets a title when the login is due for refresh at the first prompt", async () => {
  const root = createFixtureRoot("tui-due-login", JSON.stringify({ statusLine: { session: true } }));
  const issuer = startFakeIssuer({ refresh: () => "renewed-token" });
  // Not expired, but past its refresh deadline: the prompt renews it first.
  writeFxLogin(root.home, issuer.issuerUrl, "launch-token", { expiresAtMs: Date.now() + 60_000 });
  const title = titleFor((token) => token === "renewed-token");
  const gateway = startLoginGateway([title, title]);
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: loginEnv(root, gateway, issuer),
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText(FIRST_PROMPT);
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(titleTokens(gateway)).toEqual(["renewed-token"]);
    expect(issuer.refreshes).toHaveLength(1);
    expect(lastTitle(root)).toBe(GENERATED_TITLE);
  } finally {
    await tui?.kill();
    gateway.stop();
    issuer.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 60_000);

type Held = { started: boolean; cancelled: boolean };

/// A tool-free reply that keeps streaming until fx cancels it.
function heldReply(held: Held): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  return new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      held.started = true;
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "held", delta: "Working on it.\n" })}\n\n`));
      timer = setInterval(() => controller.enqueue(encoder.encode(": held\n\n")), 50);
    },
    cancel() {
      held.cancelled = true;
      if (timer) clearInterval(timer);
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

async function waitUntil(condition: () => boolean, label: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${label}`);
}

function traceHas(tracePath: string, line: string): boolean {
  return existsSync(tracePath) && readFileSync(tracePath, "utf8").includes(line);
}

test.skipIf(SKIP_TMUX)("tui titles a session once, from its first prompt, when the next prompt interrupts the first turn", async () => {
  const root = createFixtureRoot("tui-interrupted-first-turn");
  const tracePath = join(root.root, "trace.log");
  const held: Held = { started: false, cancelled: false };
  let mainRequests = 0;
  const gateway = startDynamicFakeGateway(() => {
    mainRequests += 1;
    return mainRequests === 1 ? heldReply(held) : fakeGatewayFinalText("SECOND_ANSWER_OK");
  }, {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    // The first title request fails, so only the first-prompt record keeps a
    // second one from starting.
    titleResponses: [unauthorized(), fakeGatewayFinalText(GENERATED_TITLE)],
  });
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...baseEnv(root, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "session" },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText(FIRST_PROMPT);
    await waitUntil(() => held.started, "the first turn's reply");
    // The main loop has collected the failed title task, so only the record
    // can stop the next prompt from starting another.
    await waitUntil(() => traceHas(tracePath, "event=title_generation_apply result=unavailable"), "the failed title task");
    await tui.sendText("now write the regression test for it");
    await waitUntil(() => held.cancelled, "the interrupted first turn");
    await waitUntil(() => traceHas(tracePath, "event=title_generation_skipped reason=already_started"), "the gate to refuse a second title");
    await tui.waitForText("SECOND_ANSWER_OK", 20000);
    expect(gateway.titleRequests).toHaveLength(1);
    expect(gateway.titleRequests[0]!.body).toContain("refactor the renderer loop");
    expect(sessionTitles(root)).not.toContain(GENERATED_TITLE);
    expect(lastTitle(root)).toContain("refactor the renderer loop");
  } finally {
    await tui?.kill();
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui titles the next session after /new when the first session's title failed", async () => {
  const root = createFixtureRoot("tui-new-after-failed-title", JSON.stringify({ statusLine: { session: true } }));
  const gateway = startDynamicFakeGateway(_raw => fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MAIN_MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: [unauthorized(), fakeGatewayFinalText(GENERATED_TITLE)],
  });
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
    await tui.sendText(FIRST_PROMPT);
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await waitUntil(() => gateway.titleRequests.length === 1, "the first title request");
    await tui.sendText("/new");
    await tui.waitForStableComposer(15000);
    await tui.sendText("explain the session store layout");
    await waitUntil(() => gateway.titleRequests.length === 2, "the second session's title request", 20_000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(gateway.titleRequests[1]!.body).toContain("explain the session store layout");
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
  } finally {
    await tui?.kill();
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}, 60_000);
