// Runs the real fx binary through six workspace-trust scenarios matching
// tests/tla/workspace_trust/WorkspaceTrust.tla Design "a", then has TLC replay
// the recorded observations through WorkspaceTrustTrace.tla.
//
// Set FX_TLA_BIN to test a different build (for example HEAD before the trust
// screen landed, which must be REJECTED on the first mismatching run).
import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  artifacts,
  shellQuote,
  targetHelpers,
  targetModule,
  testEnvironment,
} from "../lib/context";
import { fxBin } from "../lib/tlc";
import { checkTrace, type Answer, type Observation } from "./bridge";

const {
  FAKE_GATEWAY_MODEL,
  TmuxSession,
  fakeGatewayFinalText,
  hasEmptyComposer,
  startDynamicFakeGateway,
  tmuxAvailable,
} = await targetHelpers();
const { cleanupIsolatedTestHome, createIsolatedTestHome } = await targetModule("../evals/eval-helpers.ts");

const bin = process.env.FX_TLA_BIN ?? fxBin();
if (!existsSync(bin)) {
  throw new Error(`missing ${bin}; run zig build first or set FX_TLA_BIN or FX_BIN`);
}

const reports = join(artifacts, "tlc");
mkdirSync(reports, { recursive: true });
const TIMEOUT = 120_000;

function trustEnv(
  home: string,
  overrides: Record<string, string | undefined> = {},
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_SOUND: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "0",
    ...overrides,
  };
}

function newHome(): string {
  return realpathSync(createIsolatedTestHome());
}

function newDir(prefix: string): string {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)));
}

function initRepoWithCommit(repoDir: string): void {
  mkdirSync(repoDir, { recursive: true });
  execFileSync("git", ["init"], { cwd: repoDir, stdio: "pipe" });
  execFileSync("git", ["config", "user.name", "Test User"], { cwd: repoDir, stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "test@example.com"], { cwd: repoDir, stdio: "pipe" });
  writeFileSync(join(repoDir, "README.md"), "main\n");
  execFileSync("git", ["add", "README.md"], { cwd: repoDir, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "initial"], { cwd: repoDir, stdio: "pipe" });
}

function pretrustFolder(home: string, folder: string): void {
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    `${JSON.stringify({ workspaces: { [folder]: { trusted: true } } })}\n`,
  );
}

function isFolderTrustedInSettings(home: string, folder: string): boolean {
  const settingsPath = join(home, ".fx", "settings.json");
  if (!existsSync(settingsPath)) return false;
  const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as {
    workspaces?: Record<string, { trusted?: unknown }>;
  };
  return settings.workspaces?.[folder]?.trusted === true;
}

type ScreenState =
  | { kind: "asking"; grid: string[]; sawFolderAccess: boolean }
  | { kind: "composer"; grid: string[]; sawFolderAccess: boolean }
  | { kind: "exited"; exitStatus: number; sawFolderAccess: boolean };

function isAskingScreen(text: string): boolean {
  return text.includes("Folder access") && text.includes("❯ Yes, allow") && text.includes("No, exit");
}

function isComposerScreen(text: string): boolean {
  return !text.includes("Folder access") && hasEmptyComposer(text);
}

async function waitForTrustOrComposer(
  session: InstanceType<typeof TmuxSession>,
  timeoutMs = 15_000,
): Promise<ScreenState> {
  let sawFolderAccess = false;
  await session.waitForPane((pane) => {
    if (pane.includes("Folder access")) sawFolderAccess = true;
    return session.recordedExitStatus() !== null || isAskingScreen(pane) || isComposerScreen(pane);
  }, timeoutMs);

  const exitStatus = session.recordedExitStatus();
  if (exitStatus !== null) {
    return { kind: "exited", exitStatus, sawFolderAccess };
  }

  const grid = await session.capturePaneGrid();
  const settled = await session.waitForStableGrid(grid, undefined, 2_000);
  const settledText = settled.join("\n");
  if (settledText.includes("Folder access")) sawFolderAccess = true;
  if (isAskingScreen(settledText)) {
    return { kind: "asking", grid: settled, sawFolderAccess };
  }
  if (isComposerScreen(settledText)) {
    return { kind: "composer", grid: settled, sawFolderAccess };
  }
  throw new Error(`Settled screen is neither the Folder access prompt nor the composer.\nGrid:\n${settledText}`);
}

async function driveTuiObservation(opts: {
  id: string;
  folder: Observation["folder"];
  repoTrusted: boolean;
  planned: "yes" | "no" | "none";
  cwd: string;
  home: string;
  trustedKeyPath: string;
}): Promise<Observation> {
  const stderrDir = newDir("fx-tla-wt-stderr-");
  const stderrPath = join(stderrDir, "stderr.log");
  writeFileSync(stderrPath, "");
  const session = await TmuxSession.create({
    cmd: shellQuote(bin),
    cwd: opts.cwd,
    env: trustEnv(opts.home),
    stderrPath,
    remainOnExit: true,
    width: 100,
    height: 30,
  });

  try {
    const initial = await waitForTrustOrComposer(session);
    let answer: Answer;
    let exited: boolean;

    if (initial.kind === "asking") {
      if (opts.planned === "no") {
        await session.sendKeys("2");
        await session.waitForPane(() => session.recordedExitStatus() !== null, 10_000);
        const exitCode = session.recordedExitStatus();
        assert.equal(exitCode, 0, `${opts.id}: expected exit 0 after pressing 2, got ${exitCode}`);
        answer = "no";
        exited = true;
      } else {
        await session.sendKeys("Enter");
        const pane = await session.waitForComposer(10_000);
        assert.equal(pane.includes("Folder access"), false, `${opts.id}: Folder access remained after Enter`);
        answer = "yes";
        exited = false;
      }
    } else if (initial.kind === "composer") {
      if (initial.sawFolderAccess) {
        throw new Error(`${opts.id}: Folder access appeared before composer without an answer`);
      }
      answer = "none";
      exited = false;
    } else {
      throw new Error(`${opts.id}: fx exited prematurely with code ${initial.exitStatus}`);
    }

    const savedAfter = isFolderTrustedInSettings(opts.home, opts.trustedKeyPath);
    const stderr = readFileSync(stderrPath, "utf8");
    return {
      id: opts.id,
      surface: "tui",
      folder: opts.folder,
      repoTrusted: opts.repoTrusted,
      answer,
      exited,
      savedAfter,
      evidence: { cwd: opts.cwd, trustedKeyPath: opts.trustedKeyPath, stderr },
    };
  } finally {
    await session.kill();
    rmSync(stderrDir, { recursive: true, force: true });
  }
}

async function run1TuiRepoYes(): Promise<Observation> {
  const home = newHome();
  const repo = newDir("fx-tla-wt-r1-");
  try {
    execFileSync("git", ["init"], { cwd: repo, stdio: "pipe" });
    return await driveTuiObservation({
      id: "run-1-tui-repo-yes",
      folder: "repo",
      repoTrusted: false,
      planned: "yes",
      cwd: repo,
      home,
      trustedKeyPath: repo,
    });
  } finally {
    rmSync(repo, { recursive: true, force: true });
    cleanupIsolatedTestHome(home);
  }
}

async function run2TuiRepoNo(): Promise<Observation> {
  const home = newHome();
  const repo = newDir("fx-tla-wt-r2-");
  try {
    execFileSync("git", ["init"], { cwd: repo, stdio: "pipe" });
    return await driveTuiObservation({
      id: "run-2-tui-repo-no",
      folder: "repo",
      repoTrusted: false,
      planned: "no",
      cwd: repo,
      home,
      trustedKeyPath: repo,
    });
  } finally {
    rmSync(repo, { recursive: true, force: true });
    cleanupIsolatedTestHome(home);
  }
}

async function run3TuiWorktreeTrusted(): Promise<Observation> {
  const home = newHome();
  const root = newDir("fx-tla-wt-r3-");
  try {
    const mainRepo = join(root, "main");
    const wtDir = join(root, "wt");
    initRepoWithCommit(mainRepo);
    execFileSync("git", ["worktree", "add", wtDir], { cwd: mainRepo, stdio: "pipe" });
    const realMain = realpathSync(mainRepo);
    const realWt = realpathSync(wtDir);
    pretrustFolder(home, realMain);
    return await driveTuiObservation({
      id: "run-3-tui-worktree-trusted",
      folder: "worktree",
      repoTrusted: true,
      planned: "none",
      cwd: realWt,
      home,
      trustedKeyPath: realMain,
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
    cleanupIsolatedTestHome(home);
  }
}

async function run4TuiSpoofNo(): Promise<Observation> {
  const home = newHome();
  const root = newDir("fx-tla-wt-r4-");
  try {
    const mainRepo = join(root, "main");
    const wtDir = join(root, "wt");
    const spoofDir = join(root, "spoof");
    initRepoWithCommit(mainRepo);
    execFileSync("git", ["worktree", "add", wtDir], { cwd: mainRepo, stdio: "pipe" });
    const realMain = realpathSync(mainRepo);
    pretrustFolder(home, realMain);
    mkdirSync(spoofDir, { recursive: true });
    const realSpoof = realpathSync(spoofDir);
    writeFileSync(join(realSpoof, ".git"), `gitdir: ${realMain}/.git/worktrees/wt\n`);
    return await driveTuiObservation({
      id: "run-4-tui-spoof-no",
      folder: "spoof",
      repoTrusted: true,
      planned: "no",
      cwd: realSpoof,
      home,
      trustedKeyPath: realSpoof,
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
    cleanupIsolatedTestHome(home);
  }
}

async function run5TuiHomeYes(): Promise<Observation> {
  const home = newHome();
  try {
    return await driveTuiObservation({
      id: "run-5-tui-home-yes",
      folder: "home",
      repoTrusted: false,
      planned: "yes",
      cwd: home,
      home,
      trustedKeyPath: home,
    });
  } finally {
    cleanupIsolatedTestHome(home);
  }
}

async function run6HeadlessAsk(): Promise<Observation> {
  const home = newHome();
  const repo = newDir("fx-tla-wt-r6-");
  execFileSync("git", ["init"], { cwd: repo, stdio: "pipe" });
  const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("TRUST_ASK_OK"));
  try {
    const env = testEnvironment({
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-trust-ask-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_TEST_SKIP_WORKSPACE_TRUST: "0",
      FX_TEST_SKIP_ONBOARDING: "1",
    });
    const child = Bun.spawn([bin, "ask", "--json", "say hi"], {
      cwd: repo,
      env,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      timeout: 20_000,
      killSignal: "SIGTERM",
    });
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    assert.equal(
      code,
      0,
      `run-6-headless-repo-ask exited ${code} (signal ${child.signalCode}): ${stderr}`,
    );
    const parsed = JSON.parse(stdout.trim()) as { final_output?: string };
    assert.equal(parsed.final_output, "TRUST_ASK_OK");
    assert.equal(gateway.requestCount(), 1);
    const savedAfter = isFolderTrustedInSettings(home, repo);
    return {
      id: "run-6-headless-repo-ask",
      surface: "headless",
      folder: "repo",
      repoTrusted: false,
      answer: "none",
      exited: false,
      savedAfter,
      evidence: { exitCode: code, stderr: stderr.slice(-1000) },
    };
  } finally {
    gateway.stop();
    rmSync(repo, { recursive: true, force: true });
    cleanupIsolatedTestHome(home);
  }
}

let observed: Promise<Observation[]> | undefined;
function observations(): Promise<Observation[]> {
  observed ??= (async () => {
    const runs = [
      run1TuiRepoYes,
      run2TuiRepoNo,
      run3TuiWorktreeTrusted,
      run4TuiSpoofNo,
      run5TuiHomeYes,
      run6HeadlessAsk,
    ];
    const out: Observation[] = [];
    for (const run of runs) {
      const obs = await run();
      console.log(
        `${obs.id.padEnd(28)} surface=${obs.surface} folder=${obs.folder} ` +
        `repoTrusted=${obs.repoTrusted} answer=${obs.answer} exited=${obs.exited} savedAfter=${obs.savedAfter}`,
      );
      out.push(obs);
    }
    writeFileSync(join(artifacts, "observations.json"), JSON.stringify(out, null, 2));
    return out;
  })();
  return observed;
}

test.skipIf(!tmuxAvailable())(
  "real fx conforms to the workspace trust model",
  async () => {
    const list = await observations();
    const result = await checkTrace(list, reports);
    writeFileSync(join(artifacts, "trace.json"), JSON.stringify(result, null, 2));
    assert.equal(
      result.verdict,
      "ACCEPTED",
      `expected ACCEPTED, got ${result.verdict} (${result.firstMismatch ?? "none"}): ${result.detail}`,
    );
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "the bridge rejects tampered and empty evidence",
  async () => {
    const list = await observations();
    const tampered = list.map((item) => ({ ...item }));
    tampered[0]!.answer = "none";
    const rejected = await checkTrace(tampered, reports);
    assert.equal(rejected.verdict, "REJECTED", `expected REJECTED, got ${rejected.verdict}: ${rejected.detail}`);
    assert.equal(rejected.firstMismatch, tampered[0]!.id);

    const empty = await checkTrace([], reports);
    assert.equal(empty.verdict, "TOOL_ERROR", `expected TOOL_ERROR, got ${empty.verdict}: ${empty.detail}`);
  },
  TIMEOUT,
);
