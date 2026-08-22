// Model-backed eval helpers. Requires a built binary and AI_GATEWAY_API_KEY.
import { expect } from "bun:test";
import { execFileSync, execSync, spawn as nodeSpawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export const FX_BIN = resolve(import.meta.dirname, "../../zig-out/bin/fx");
export const REPO_ROOT = resolve(import.meta.dirname, "../..");

export const EVAL_MODELS = [
  "anthropic/claude-sonnet-4.6",
  "xai/grok-4.20-multi-agent-beta",
] as const;

export const EVAL_MODEL: string = process.env.EVAL_MODEL ?? EVAL_MODELS[0];

function loadDotEnv(): Record<string, string> {
  const candidates = [join(REPO_ROOT, ".env"), join(REPO_ROOT, ".env.local")];
  const vars: Record<string, string> = {};
  for (const file of candidates) {
    if (!existsSync(file)) continue;
    const lines = readFileSync(file, "utf-8").split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq < 0) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      vars[key] = value;
    }
  }
  return vars;
}

export function shouldLoadDotEnv(
  environment: NodeJS.ProcessEnv = process.env,
): boolean {
  return environment.FX_E2E_DISABLE_DOTENV !== "1";
}

const dotEnvVars = shouldLoadDotEnv() ? loadDotEnv() : {};

for (const [k, v] of Object.entries(dotEnvVars)) {
  if (!process.env[k]) process.env[k] = v;
}

export interface HeadlessResult {
  output: string;
  exit_code: number;
  model: string;
  session_id: string;
  steps: number;
  tool_calls: Array<{
    name: string;
    status: string;
    command_result?: {
      kind?: string;
      command?: string;
      cwd?: string;
      exit_code?: number;
      signal?: string | null;
      timed_out?: boolean;
      stdout_bytes?: number;
      stderr_bytes?: number;
      truncated?: boolean;
    };
    question?: string;
  }>;
  error?: string;
}

export interface EvalResult {
  json: HeadlessResult;
  stdout: string;
  stderr: string;
  code: number | null;
  workDir: string;
}

export interface EvalOptions {
  timeoutSec?: number;
  cwd?: string;
  model?: string;
  setup?: (dir: string) => Promise<void>;
}

const PREFIX = "fx-eval-";
const HOME_PREFIX = "fx-eval-home-";
const TEST_HOME_PREFIX = "fx-test-home-";

export function createWorkDir(): string {
  return mkdtempSync(join(tmpdir(), PREFIX));
}

export function cleanupWorkDir(dir: string): void {
  try {
    nodeSpawn("rm", ["-rf", dir], { stdio: "ignore", detached: true }).unref();
  } catch {}
}

export function createIsolatedTestHome(): string {
  return mkdtempSync(join(tmpdir(), TEST_HOME_PREFIX));
}

export function cleanupIsolatedTestHome(home: string): void {
  rmSync(home, { recursive: true, force: true });
}

function createEvalHome(): string {
  const home = mkdtempSync(join(tmpdir(), HOME_PREFIX));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "auto",
      permission: {
        bash: "allow",
        copy_file: "allow",
        create_folder: "allow",
        delete_file: "allow",
        edit: "allow",
        read: "allow",
        rename_file: "allow",
      },
    }) + "\n",
    { mode: 0o600 },
  );
  return home;
}

function cleanupEvalHome(home: string): void {
  rmSync(home, { recursive: true, force: true });
}

export function buildEvalProcessEnv(
  home: string,
  model: string,
): Record<string, string | undefined> {
  return {
    ...dotEnvVars,
    ...process.env,
    NO_COLOR: "1",
    HOME: home,
    PATH: process.env.PATH ?? "",
    FX_MODEL: model,
  };
}

export async function runEval(
  prompt: string,
  opts: EvalOptions = {},
): Promise<EvalResult> {
  const { timeoutSec = 300, model = EVAL_MODEL, setup } = opts;

  const workDir = opts.cwd ?? createWorkDir();
  const home = createEvalHome();

  try {
    if (setup) {
      await setup(workDir);
    }

    if (!existsSync(FX_BIN)) {
      throw new Error(
        `fx binary not found at ${FX_BIN}. Run 'zig build' first.`,
      );
    }

    const args = [
      "ask",
      "--auto",
      "--json",
      "--no-save",
      "--timeout",
      String(timeoutSec * 1000),
      prompt,
    ];

    const result = await new Promise<{
      stdout: string;
      stderr: string;
      code: number | null;
    }>((resolvePromise) => {
      const env = buildEvalProcessEnv(home, model);
      const child = nodeSpawn(FX_BIN, args, {
        env,
        cwd: workDir,
        stdio: ["pipe", "pipe", "pipe"],
      });

      const stdoutBufs: Buffer[] = [];
      const stderrBufs: Buffer[] = [];
      child.stdout.on("data", (d: Buffer) => stdoutBufs.push(d));
      child.stderr.on("data", (d: Buffer) => stderrBufs.push(d));
      child.stdin.end();

      child.on("close", (code: number | null) => {
        resolvePromise({
          stdout: Buffer.concat(stdoutBufs).toString(),
          stderr: Buffer.concat(stderrBufs).toString(),
          code,
        });
      });
    });

    let json: HeadlessResult;
    try {
      json = JSON.parse(result.stdout.trim());
    } catch {
      throw new Error(
        `Failed to parse fx JSON output.\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
      );
    }

    console.log("\n--- eval result ---");
    console.log(`  exit code: ${result.code}`);
    console.log(`  json.exit_code: ${json.exit_code}`);
    console.log(`  json.model: ${json.model}`);
    console.log(`  json.steps: ${json.steps}`);
    console.log(`  json.tool_calls: ${json.tool_calls?.length ?? 0}`);
    console.log(`  json.output length: ${json.output.length}`);
    if (json.error) {
      console.log(`  json.error: ${json.error}`);
      console.log(`  json.output: ${json.output.slice(0, 500)}`);
    }
    if (result.stderr) {
      console.log(`  stderr (last 500): ${result.stderr.slice(-500)}`);
    }
    console.log("--- end eval result ---\n");

    if (json.error) {
      throw new Error(
        `fx returned error: ${json.error}\nstderr: ${result.stderr.slice(-1000)}`,
      );
    }

    return {
      json,
      stdout: result.stdout,
      stderr: result.stderr,
      code: result.code,
      workDir,
    };
  } finally {
    cleanupEvalHome(home);
  }
}

export function assertFileExists(dir: string, relativePath: string): void {
  const full = join(dir, relativePath);
  expect(existsSync(full)).toBe(true);
}

export function assertNoFile(dir: string, relativePath: string): void {
  const full = join(dir, relativePath);
  expect(existsSync(full)).toBe(false);
}

export function assertFileContains(
  dir: string,
  relativePath: string,
  pattern: string | RegExp,
): void {
  const full = join(dir, relativePath);
  expect(existsSync(full)).toBe(true);
  const content = readFileSync(full, "utf-8");
  if (typeof pattern === "string") {
    expect(content).toContain(pattern);
  } else {
    expect(content).toMatch(pattern);
  }
}

export function assertAnyFileContains(
  dir: string,
  extensions: string[],
  pattern: string,
): void {
  const extArgs = extensions.map((e) => `--include=*.${e}`).join(" ");
  try {
    execSync(`grep -r ${extArgs} -l ${JSON.stringify(pattern)} .`, {
      cwd: dir,
      stdio: "pipe",
    });
  } catch {
    throw new Error(
      `No file with extensions [${extensions.join(", ")}] in ${dir} contains "${pattern}"`,
    );
  }
}

export function assertCommandSucceeds(
  dir: string,
  cmd: string,
  timeoutMs = 120_000,
): void {
  try {
    execSync(cmd, { cwd: dir, stdio: "pipe", timeout: timeoutMs });
  } catch (e) {
    const stderr =
      e && typeof e === "object" && "stderr" in e
        ? (e as { stderr: Buffer }).stderr?.toString()
        : "";
    throw new Error(`Command failed in ${dir}: ${cmd}\n${stderr}`);
  }
}

export function assertAnyFileExists(
  dir: string,
  relativePaths: string[],
): void {
  const found = relativePaths.some((p) => existsSync(join(dir, p)));
  if (!found) {
    throw new Error(`None of [${relativePaths.join(", ")}] exist in ${dir}`);
  }
}

export function assertStepCount(
  result: EvalResult,
  bounds: { min?: number; max?: number },
): void {
  const { steps } = result.json;
  if (bounds.min !== undefined) {
    expect(steps).toBeGreaterThanOrEqual(bounds.min);
  }
  if (bounds.max !== undefined) {
    expect(steps).toBeLessThanOrEqual(bounds.max);
  }
}

export function assertToolUsed(
  result: EvalResult,
  toolName: string,
): void {
  const used = result.json.tool_calls?.some((tc) => tc.name === toolName);
  expect(used).toBe(true);
}

export function assertFirstToolIn(
  result: EvalResult,
  toolNames: readonly string[],
): void {
  const first = result.json.tool_calls?.[0]?.name;
  expect(first, `expected first tool to be one of ${toolNames.join(", ")}`).toBeDefined();
  expect(toolNames).toContain(first!);
}

export function assertToolNotUsed(
  result: EvalResult,
  toolName: string,
): void {
  const used = result.json.tool_calls?.some((tc) => tc.name === toolName);
  expect(used).toBe(false);
}

export function assertNoAskUserQuestionMatching(
  result: EvalResult,
  pattern: string | RegExp,
): void {
  const askCalls = result.json.tool_calls?.filter(
    (tc) => tc.name === "ask_user_question",
  ) ?? [];
  if (askCalls.length === 0) return;

  const matchingOrUninspectable = askCalls.some((tc) => {
    const question = tc.question;
    if (!question) return true;
    return typeof pattern === "string"
      ? question.includes(pattern)
      : pattern.test(question);
  });
  expect(matchingOrUninspectable).toBe(false);
}

export function assertTerminalExecMatches(
  result: EvalResult,
  pattern: RegExp,
): void {
  const matched = recordedTerminalExecCommands(result).some((command) => pattern.test(command));
  expect(matched).toBe(true);
}

export function assertNoTerminalExecMatches(
  result: EvalResult,
  pattern: RegExp,
): void {
  const matched = recordedTerminalExecCommands(result).some((command) => pattern.test(command));
  expect(matched).toBe(false);
}

function recordedTerminalExecCommands(result: EvalResult): string[] {
  const commands = new Set<string>();
  for (const tc of result.json.tool_calls ?? []) {
    if (tc.name !== "terminal") continue;
    const command = tc.command_result?.command;
    if (command) commands.add(command);
  }
  for (const match of result.stderr.matchAll(/^Running (.+)$/gm)) {
    const command = match[1]?.trim();
    if (command) commands.add(command);
  }
  return [...commands];
}

export function assertFirstTerminalExecMatches(
  result: EvalResult,
  pattern: RegExp,
): void {
  const first = result.json.tool_calls?.[0];
  expect(first?.name).toBe("terminal");
  expect(pattern.test(first?.command_result?.command ?? "")).toBe(true);
}

// Generic fx CLI runner for deterministic command coverage.

export interface FxRunResult {
  stdout: string;
  stderr: string;
  code: number | null;
  signal: NodeJS.Signals | null;
  timedOut: boolean;
  killSent: boolean;
  elapsedMs: number;
  pid: number | null;
  processStateAtTimeout: string;
  processStateAfterClose: string;
}

function captureFxProcessState(): string {
  try {
    return execFileSync("ps", ["-axo", "pid,ppid,stat,etime,command"], {
      encoding: "utf8",
    }).split("\n").filter((line) =>
      line.includes("/zig-out/bin/fx") ||
      line.includes("mcp-modern-") ||
      line.includes("mcp-legacy-") ||
      line.includes("bun test")
    ).join("\n");
  } catch {
    return "process snapshot unavailable";
  }
}

export async function runFx(
  args: string[],
  opts: {
    cwd?: string;
    env?: Record<string, string | undefined>;
    stdin?: string | Uint8Array;
    timeoutMs?: number;
  } = {},
): Promise<FxRunResult> {
  if (!existsSync(FX_BIN)) {
    throw new Error(`fx binary not found at ${FX_BIN}. Run 'zig build' first.`);
  }

  const { cwd, timeoutMs = 15_000 } = opts;

  return new Promise<FxRunResult>((resolvePromise) => {
    const env: Record<string, string | undefined> = {
      ...dotEnvVars,
      ...process.env,
      NO_COLOR: "1",
      HOME: process.env.HOME ?? "",
      PATH: process.env.PATH ?? "",
    };
    for (const [key, value] of Object.entries(opts.env ?? {})) {
      if (value === undefined) {
        delete env[key];
      } else {
        env[key] = value;
      }
    }
    const child = nodeSpawn(FX_BIN, args, {
      env,
      cwd: cwd ?? REPO_ROOT,
      stdio: ["pipe", "pipe", "pipe"],
    });

    const stdoutBufs: Buffer[] = [];
    const stderrBufs: Buffer[] = [];
    child.stdout.on("data", (d: Buffer) => stdoutBufs.push(d));
    child.stderr.on("data", (d: Buffer) => stderrBufs.push(d));
    child.stdin.end(opts.stdin);

    const startedAtMs = performance.now();
    let timedOut = false;
    let killSent = false;
    let processStateAtTimeout = "";
    const timer = setTimeout(() => {
      timedOut = true;
      processStateAtTimeout = captureFxProcessState();
      killSent = child.kill("SIGKILL");
    }, timeoutMs);

    child.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      clearTimeout(timer);
      resolvePromise({
        stdout: Buffer.concat(stdoutBufs).toString(),
        stderr: Buffer.concat(stderrBufs).toString(),
        code,
        signal,
        timedOut,
        killSent,
        elapsedMs: performance.now() - startedAtMs,
        pid: child.pid ?? null,
        processStateAtTimeout,
        processStateAfterClose: code === 0 && !timedOut ? "" : captureFxProcessState(),
      });
    });
  });
}

export const HAS_API_KEY: boolean = !!(
  process.env.AI_GATEWAY_API_KEY || process.env.VERCEL_OIDC_TOKEN
);
