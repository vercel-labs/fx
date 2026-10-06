// RPC ownership and correlation proofs remain separate from offline discovery.
import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";
import { EXTENSION_FIXTURE_KEY, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, VALID_MANIFEST, VALID_REGISTRY, createExtensionProfile } from "./fixtures/extension-profile";

const TIMEOUT_MS = 15_000;
const TUI_TIMEOUT_MS = 5_000;
const CLI_APPROVAL_ARGUMENTS = ["ask", "--json", "--prompt-permissions", "--no-save"];
const CLI_APPROVAL_EXIT_FORMAT = "%s\\n";
const CLI_APPROVAL_SHELL = "/bin/sh";
const CLI_APPROVAL_STATUS_SUFFIX = ".status";
const MODE_CHANGE_COMMAND = "/permissions auto";
const MODE_CHANGE_NOTICE = "mode set to auto";
const AUTO_REVIEW_UNAVAILABLE_ERROR = "ExtensionExecutionAutoReviewUnavailable";
const CLI_APPROVAL_OUTPUT_FILENAME = "native-approval-output.json";
const CLI_APPROVAL_PROMPT = "Approve? [y/N]";
const CLI_PRIVILEGE_WARNING = "not sandboxed";
const CLI_APPROVAL_CASES = [ { decision: "approve", answer: "y", exitCode: 0 }, { decision: "deny", answer: "n", exitCode: 1 } ];
const TUI_STDERR_FILENAME = "fx-stderr.log";
const EXECUTABLE_CHANGE_COMMENT = "\n// Changed identity requires a new native launch decision.\n";
const EXECUTABLE_CHANGED_ERROR = "ExtensionExecutableChanged";
const SECOND_PROVIDER_ID = "second-provider";
const SECOND_PROVIDER_MODEL = `${SECOND_PROVIDER_ID}/fixture-model`;
const NATIVE_APPROVAL_LABEL = "Execute trusted extension";
const ASK_PERMISSION_MODE = "ask";
const NATIVE_PERMISSION_NAME = "extension_execute";
const NATIVE_SETTINGS_FILENAME = "settings.json";
const ACTIVATION_FAILURE_CASES = [
  { mode: "ask", permission: "deny", error: "ExtensionExecutionDenied" },
  { mode: "ask", permission: "ask", error: "PermissionPromptUnavailable" },
  { mode: "auto", permission: "ask", error: "ExtensionExecutionAutoReviewUnavailable" },
];
const AUTH_SCOPE_PROMPT = "check scoped authentication";
const RPC_RESULT_TEXT = "extension-rpc-ok";
const YOLO_WARNING_TEXT = "YOLO enabled: fx permission checks disabled\n";
const RPC_LOG_FILENAME = "rpc-log.jsonl";
const MISSING_FINISH_FILENAME = "missing-finish";
const DROP_STREAM_FILENAME = "drop-stream";
const STREAM_MODE_FILENAME = "stream-events";
const STREAM_FINISHED_FILENAME = "stream-finished";
const STREAM_PREFIX = "extension-first-chunk";
const STREAM_RESULT = `${STREAM_PREFIX}-completed`;
const FOREIGN_MODE_FILENAME = "foreign-handle";
const FOREIGN_TEXT = "foreign-event-must-not-render";
const CANCELLED_TEXT = "System: cancelled";
const FOLLOWUP_PROMPT = "complete a new extension request";
const LARGE_EVENT_FILENAME = "large-event";
const MISMATCH_FILENAME = "content-mismatch";
const TOOL_MODE_FILENAME = "tool-roundtrip";
const TOOL_FILENAME = "fixture-tool-data.txt";
const TOOL_CONTENT = "fixture-tool-read-marker";
const TOOL_RESULT_TEXT = "extension-tool-loop-ok";
const MANIFEST_FILENAME = "extension.json";
const SESSION_HEADERS = { "x-opencode-session": { source: "session_id" } };
const UNRESTRICTED_PERMISSION_MODE = "yolo";
const ASK_ARGUMENTS = ["ask", "--json", "--no-save", AUTH_SCOPE_PROMPT];
const FIXTURE_EXECUTABLE_MODE = 0o700;
const RPC_FIXTURE_SOURCE_PATH = join(import.meta.dir, "fixtures", "extension-provider.ts");
const tuiTest = tmuxAvailable() ? test.serial : test.skip;
const homes: string[] = [];

// Caller-owned homes prevent executable state from crossing scenario boundaries.
function fixture(): { home: string; extension: string } {
  const home = createExtensionProfile(VALID_REGISTRY, VALID_MANIFEST);
  homes.push(home);
  const extension = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY);
  const executable = join(extension, VALID_MANIFEST.entrypoint);
  writeFileSync(executable, `#!${process.execPath}\n${readFileSync(RPC_FIXTURE_SOURCE_PATH, "utf8")}`);
  chmodSync(executable, FIXTURE_EXECUTABLE_MODE);
  return { home, extension };
}

// One fake account drives CLI proofs without inherited native credentials or keychain access.
function askFixture(home: string, permissionMode = UNRESTRICTED_PERMISSION_MODE) {
  return spawnSync(FX_BIN, ASK_ARGUMENTS, {
    cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
    env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
      FX_MODEL: undefined, FX_PERMISSION_MODE: permissionMode, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
      FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1" },
  });
}

afterEach(() => { for (const home of homes.splice(0)) cleanupIsolatedTestHome(home); });

describe("local extension RPC runtime", () => {
  // A held launch must not run initialize, even when the extension could remain HTTP-idle.
  test.each(ACTIVATION_FAILURE_CASES)("native $mode activation holds $permission without spawning", ({ mode, permission, error }) => {
    const { home, extension } = fixture();
    const settingsPath = join(home, PROFILE_DIRECTORY, NATIVE_SETTINGS_FILENAME);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.permission = { [NATIVE_PERMISSION_NAME]: permission };
    writeFileSync(settingsPath, JSON.stringify(settings));
    const result = askFixture(home, mode);
    expect(result.status).not.toBe(0);
    expect(JSON.parse(result.stdout).error).toBe(error);
    expect(existsSync(join(extension, RPC_LOG_FILENAME))).toBe(false);
    expect(result.stdout + result.stderr).not.toContain(EXTENSION_FIXTURE_KEY);
  });

  test("native file tool results and empty reasoning state replay to the next request", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, TOOL_MODE_FILENAME), "");
    writeFileSync(join(extension, MANIFEST_FILENAME), JSON.stringify({ ...VALID_MANIFEST, providers: [{
      ...VALID_MANIFEST.providers[0], headers: SESSION_HEADERS,
    }] }));
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(0);
    expect(JSON.parse(result.stdout).output).toBe(TOOL_RESULT_TEXT);
    expect(result.stderr).toContain(YOLO_WARNING_TEXT);
    expect(result.stderr).toContain(TOOL_FILENAME);
    expect(result.stderr).not.toContain(EXTENSION_FIXTURE_KEY);
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method === "initialize")).toHaveLength(1);
    expect(calls.filter(call => call.method === "provider.prepare")).toHaveLength(2);
    const streams = calls.filter(call => call.method === "provider.stream");
    expect(streams).toHaveLength(2);
    expect(streams[0].sessionId).toBeTruthy();
    expect(streams.map(call => call.sessionHeader)).toEqual([streams[0].sessionId, streams[0].sessionId]);
    expect(() => process.kill(calls[0].pid, 0)).toThrow();
  });

  test("oversized events remain bounded and never repeat a possibly billed stream", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, LARGE_EVENT_FILENAME), "");
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(1);
    expect(JSON.parse(result.stdout).error).toBe("ExtensionEventOverflow");
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(1);
    expect(() => process.kill(calls[0].pid, 0)).toThrow();
  });

  test("completion cannot rewrite already delivered content", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, MISMATCH_FILENAME), "");
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(1);
    expect(JSON.parse(result.stdout).error).toBe("ExtensionEventContentMismatch");
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(1);
    expect(() => process.kill(calls[0].pid, 0)).toThrow();
  });

  test("foreign handle notifications never reach the request transcript", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, FOREIGN_MODE_FILENAME), "");
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(1);
    expect(JSON.parse(result.stdout).error).toBe("ExtensionEventCorrelationInvalid");
    expect(result.stdout).not.toContain(FOREIGN_TEXT);
    expect(result.stderr).toBe(YOLO_WARNING_TEXT);
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method !== "provider.cancel").map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
    expect(calls.filter(call => call.method === "provider.cancel").length).toBeLessThanOrEqual(1);
    expect(calls.filter(call => call.method !== "provider.cancel").map(call => call.credential)).toEqual([false, false, true, false]);
    expect(calls.every(call => !call.ambientKey)).toBe(true);
    expect(() => process.kill(calls[0].pid, 0)).toThrow();
  });

  tuiTest.each(CLI_APPROVAL_CASES)("native CLI human $decision preserves JSON and exact launch", async ({ decision, answer, exitCode }) => {
    const { home, extension } = fixture();
    const stdoutPath = join(home, CLI_APPROVAL_OUTPUT_FILENAME);
    writeFileSync(stdoutPath, "");
    const statusPath = stdoutPath + CLI_APPROVAL_STATUS_SUFFIX;
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({
        cmd: CLI_APPROVAL_SHELL,
        cwd: home, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: ASK_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1" },
      });
      await session.sendText(`${[FX_BIN, ...CLI_APPROVAL_ARGUMENTS, AUTH_SCOPE_PROMPT].map(arg => JSON.stringify(arg)).join(" ")} > ${JSON.stringify(stdoutPath)}; printf ${JSON.stringify(CLI_APPROVAL_EXIT_FORMAT)} "$?" > ${JSON.stringify(statusPath)}`);
      const prompt = await session.waitForText(CLI_APPROVAL_PROMPT, TUI_TIMEOUT_MS);
      expect(prompt).toContain(CLI_PRIVILEGE_WARNING);
      expect(existsSync(join(extension, RPC_LOG_FILENAME))).toBe(false);
      await session.sendText(answer);
      await session.waitForPane(() => existsSync(statusPath), TUI_TIMEOUT_MS);
      expect(Number(readFileSync(statusPath, "utf8").trim())).toBe(exitCode);
      const stdout = readFileSync(stdoutPath, "utf8");
      expect(stdout).not.toContain(CLI_APPROVAL_PROMPT);
      expect(stdout).not.toContain(EXTENSION_FIXTURE_KEY);
      const result = JSON.parse(stdout);
      if (decision === "approve") {
        expect(result.output).toBe(RPC_RESULT_TEXT);
        const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
        expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
      } else {
        expect(result.error).toBe("ExtensionExecutionDenied");
        expect(existsSync(join(extension, RPC_LOG_FILENAME))).toBe(false);
      }
    } catch (error) {
      throw new Error(String(error) + "\nCLI output: " + readFileSync(stdoutPath, "utf8") + "\n" + (session ? await session.capturePane() : ""));
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

  tuiTest("a retained child cannot reuse ask approval after switching to auto", async () => {
    const { home, extension } = fixture();
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: ASK_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Enter");
      await session.waitForText(RPC_RESULT_TEXT, TUI_TIMEOUT_MS);
      await session.sendText(MODE_CHANGE_COMMAND);
      await session.waitForText(MODE_CHANGE_NOTICE, TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      const pane = await session.waitForText(AUTO_REVIEW_UNAVAILABLE_ERROR, TUI_TIMEOUT_MS);
      expect(pane).not.toContain(NATIVE_APPROVAL_LABEL);
      expect(session.isAlive()).toBe(true);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
      expect(() => process.kill(calls[0].pid, 0)).toThrow();
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

  tuiTest("an executable changed during human approval never starts before reapproval", async () => {
    const { home, extension } = fixture();
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: ASK_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      const executable = join(extension, VALID_MANIFEST.entrypoint);
      writeFileSync(executable, readFileSync(executable, "utf8") + EXECUTABLE_CHANGE_COMMENT);
      await session.sendKeys("Enter");
      await session.waitForText(EXECUTABLE_CHANGED_ERROR, TUI_TIMEOUT_MS);
      expect(existsSync(join(extension, RPC_LOG_FILENAME))).toBe(false);
      expect(session.isAlive()).toBe(true);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Enter");
      await session.waitForText(RPC_RESULT_TEXT, TUI_TIMEOUT_MS);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.filter(call => call.method === "initialize")).toHaveLength(1);
      expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

  tuiTest("native child approval cannot cross provider identities", async () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, MANIFEST_FILENAME), JSON.stringify({ ...VALID_MANIFEST, providers: [VALID_MANIFEST.providers[0], { ...VALID_MANIFEST.providers[0], id: SECOND_PROVIDER_ID }] }));
    const catalogPath = join(extension, VALID_MANIFEST.providers[0].models_file);
    const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
    catalog.models[0].reasoning = false;
    catalog.models[0].reasoning_efforts = [];
    writeFileSync(catalogPath, JSON.stringify(catalog));
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: ASK_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Enter");
      await session.waitForText(RPC_RESULT_TEXT, TUI_TIMEOUT_MS);
      expect(await session.capturePane()).not.toContain(NATIVE_APPROVAL_LABEL);
      await session.sendText("/model");
      await session.waitForText(SECOND_PROVIDER_MODEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      const selected = JSON.parse(readFileSync(join(home, PROFILE_DIRECTORY, NATIVE_SETTINGS_FILENAME), "utf8"));
      expect(selected.models.extension).toBe(SECOND_PROVIDER_MODEL);
      await session.sendText(AUTH_SCOPE_PROMPT);
      const pending = await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      expect(pending).toContain(SECOND_PROVIDER_ID);
      const held = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(held.filter(call => call.method === "provider.stream")).toHaveLength(1);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("ExtensionExecutionDenied", TUI_TIMEOUT_MS);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

  tuiTest("native terminal confirms exact executable before initialization without yolo", async () => {
    const { home, extension } = fixture();
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: ASK_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      const pending = await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      expect(pending).toContain("OS privileges");
      expect(existsSync(join(extension, RPC_LOG_FILENAME))).toBe(false);
      await session.sendKeys("Enter");
      await session.waitForText(RPC_RESULT_TEXT, TUI_TIMEOUT_MS);
      expect(session.isAlive()).toBe(true);
      const executable = join(extension, VALID_MANIFEST.entrypoint);
      writeFileSync(executable, readFileSync(executable, "utf8") + EXECUTABLE_CHANGE_COMMENT);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(NATIVE_APPROVAL_LABEL, TUI_TIMEOUT_MS);
      const retired = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(retired.filter(call => call.method === "shutdown")).toHaveLength(1);
      expect(() => process.kill(retired[0].pid, 0)).toThrow();
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("ExtensionExecutionDenied", TUI_TIMEOUT_MS);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
      expect(() => process.kill(calls[0].pid, 0)).toThrow();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

  tuiTest("a terminal receives content before the provider completion", async () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, STREAM_MODE_FILENAME), "");
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: UNRESTRICTED_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(STREAM_PREFIX, TUI_TIMEOUT_MS);
      expect(existsSync(join(extension, STREAM_FINISHED_FILENAME))).toBe(false);
      const pane = await session.waitForText(STREAM_RESULT, TUI_TIMEOUT_MS);
      expect(pane.split(STREAM_PREFIX)).toHaveLength(2);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
      expect(() => process.kill(calls[0].pid, 0)).toThrow();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);


  tuiTest("cancellation retires the child and a fresh user request starts cleanly", async () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, STREAM_MODE_FILENAME), "");
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: UNRESTRICTED_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(STREAM_PREFIX, TUI_TIMEOUT_MS);
      expect(existsSync(join(extension, STREAM_FINISHED_FILENAME))).toBe(false);
      await session.sendKeys("C-c");
      await session.waitForText(CANCELLED_TEXT, TUI_TIMEOUT_MS);
      expect(existsSync(join(extension, STREAM_FINISHED_FILENAME))).toBe(false);
      expect(session.isAlive()).toBe(true);
      await session.sendText(FOLLOWUP_PROMPT);
      await session.waitForText(STREAM_RESULT, TUI_TIMEOUT_MS);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.filter(call => call.method === "provider.cancel")).toHaveLength(1);
      expect(calls.filter(call => call.method === "initialize")).toHaveLength(2);
      expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(2);
      expect(new Set(calls.map(call => call.pid)).size).toBe(2);
      expect(() => process.kill(calls[0].pid, 0)).toThrow();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);


  test("explicit yolo admits one scoped RPC request without ambient credentials", () => {
    const { home, extension } = fixture();
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(0);
    expect(JSON.parse(result.stdout).output).toBe(RPC_RESULT_TEXT);
    expect(result.stderr).toBe(YOLO_WARNING_TEXT);
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
    expect(calls.map(call => call.credential)).toEqual([false, false, true, false]);
    expect(calls.every(call => !call.ambientKey)).toBe(true);
    expect(() => process.kill(calls[0].pid, 0)).toThrow();
  });

  test("missing completion evidence never automatically repeats an admitted request", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, MISSING_FINISH_FILENAME), "");
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(1);
    expect(JSON.parse(result.stdout).error).toBe("ExtensionCompletionInvalid");
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(1);
    expect(result.stderr).toBe(YOLO_WARNING_TEXT);
  });

  test("lost admitted RPC response never automatically restarts the executable", () => {
    const { home, extension } = fixture();
    writeFileSync(join(extension, DROP_STREAM_FILENAME), "");
    const result = askFixture(home);
    expect(result.status, result.stderr || result.stdout).toBe(1);
    expect(JSON.parse(result.stdout).error).toBe("ExtensionStreamAmbiguous");
    const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(calls.filter(call => call.method === "initialize")).toHaveLength(1);
    expect(calls.filter(call => call.method === "provider.stream")).toHaveLength(1);
    expect(result.stderr).toBe(YOLO_WARNING_TEXT);
  });

  tuiTest("a real terminal completes admitted RPC and retires its child on normal quit", async () => {
    const { home, extension } = fixture();
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_PERMISSION_MODE: UNRESTRICTED_PERMISSION_MODE, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0" },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      await session.waitForText(RPC_RESULT_TEXT, TUI_TIMEOUT_MS);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      const calls = readFileSync(join(extension, RPC_LOG_FILENAME), "utf8").trim().split("\n").map(line => JSON.parse(line));
      expect(calls.map(call => call.method)).toEqual(["initialize", "provider.prepare", "provider.stream", "shutdown"]);
      expect(() => process.kill(calls[0].pid, 0)).toThrow();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); }
  }, TIMEOUT_MS);

});
