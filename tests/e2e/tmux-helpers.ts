/**
 * tmux helper for interactive TUI testing.
 *
 * Creates isolated tmux sessions, sends keystrokes, captures pane
 * output, and provides waitForText polling for assertions.
 *
 * Requires: tmux installed and available in PATH.
 */
import { execFileSync, execSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, providerVersionTestEnv } from "../evals/eval-helpers";

let sessionCounter = 0;

export const FAKE_GATEWAY_MODEL = "openai/gpt-5";
const TMUX_CAPTURE_MAX_BUFFER = 32 * 1024 * 1024;
const TMUX_HEX_CHUNK_BYTES = 256;
const COMPOSER_LINE = /^[ \t]*(?:┃|❯|>)(?:[ \t]|$)/;
const AUTH_ENV_KEYS = [
  "AI_GATEWAY_API_KEY",
  "VERCEL_OIDC_TOKEN",
] as const;
const DEFAULT_UNSET_ENV_KEYS = [
  ...AUTH_ENV_KEYS,
  "FX_E2E_GATEWAY_CHAT_URL",
  "FX_E2E_GATEWAY_MODELS_URL",
  "FX_E2E_GATEWAY_CREDITS_URL",
  "FX_E2E_UPGRADE_BASE_URL",
  "FX_PERMISSION_MODE",
] as const;
const MIRRORED_ENV_KEYS = [
  "FX_GATEWAY_BASE_URL",
  "FX_GATEWAY_CHAT_URL",
  "FX_MAX_AGENT_STEPS",
  "FX_MODEL",
] as const;

export function canonicalSubagentIdForStore(childId: string): string {
  const match = /^(\d+)-(\d{6})-([0-9a-f]{16})$/.exec(childId);
  return match ? `${match[1]}-${match[1]}${match[2]}-${match[3]}` : childId;
}

export function terminalFixtureShell(): string {
  for (const path of ["/bin/zsh", "/bin/bash"]) {
    if (existsSync(path)) return path;
  }
  throw new Error("terminal fixtures require Bash or zsh");
}

const TMUX_RAW_PASTE_FLAGS = (() => {
  try {
    const version = execFileSync("tmux", ["-V"], { encoding: "utf8" })
      .trim()
      .match(/^tmux (\d+)\.(\d+)/);
    if (!version) return [] as const;
    const major = Number(version[1]);
    const minor = Number(version[2]);
    return major > 3 || (major === 3 && minor >= 7) ? (["-S"] as const) : [];
  } catch {
    return [] as const;
  }
})();

export function tmuxRawPasteFlags(): readonly string[] {
  return TMUX_RAW_PASTE_FLAGS;
}

export function paneExitMatches(
  pane: { dead: boolean; status: number | null },
  expectedStatus: number,
): boolean {
  return pane.dead && pane.status === expectedStatus;
}

export function isVolatileTokenStatusRow(line: string): boolean {
  return /^\s*(?:(?:\d+s|\d+m \d+s|\d+h \d{2}m) )?\(↑\d+(?:\.\d+)?k? ↓\d+(?:\.\d+)?k?\)$/.test(
    line,
  );
}

export function parseSingleChildPid(output: string, parentPid: number): number {
  const lines = output.trim().length === 0 ? [] : output.trim().split(/\s+/);
  if (lines.length !== 1) {
    throw new Error(
      `tmux pane process ${parentPid} has ${lines.length} direct children`,
    );
  }
  const pid = Number.parseInt(lines[0]!, 10);
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    throw new Error(`invalid child PID for tmux pane process ${parentPid}`);
  }
  return pid;
}

export function buildObservedCommand(
  command: string,
  stderrPath: string | undefined,
  exitStatusPath: string,
): string {
  const childCommand = stderrPath
    ? `/bin/sh -c ${shellQuote(`exec ${command} 2>${shellQuote(stderrPath)}`)}`
    : command;
  const observer = `/bin/sh -c ${shellQuote([
    childCommand,
    "status=$?",
    `printf '%s\\n' \"$status\" > ${shellQuote(exitStatusPath)}`,
    'exit "$status"',
  ].join("; "))}`;
  return stderrPath ? `${observer} 2>/dev/null` : observer;
}

export function isComposerLine(line: string): boolean {
  return COMPOSER_LINE.test(line);
}

export function isEmptyComposerLine(line: string): boolean {
  return isComposerLine(line) && line.trim().length === 1;
}

export function composerContains(pane: string, text: string): boolean {
  return pane.split("\n").some((line) => isComposerLine(line) && line.includes(text));
}

export function hasEmptyComposer(pane: string): boolean {
  return pane.split("\n").some(isEmptyComposerLine);
}

export function fakeGatewaySse(events: object[]) {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

export function fakeGatewayToolCall(
  id: string,
  name: string,
  input: object,
) {
  return fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: id,
      toolName: name,
      input,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

export function fakeShellRun(
  id: string,
  command: string,
  options: Record<string, unknown> = {},
) {
  return fakeGatewayToolCall(id, "shell", {
    request: {
      yield_time_ms: 30_000,
      ...options,
      action: "run",
      command,
    },
  });
}

export function fakeGatewayPermissionDecision(
  decision: "clear" | "caution" = "clear",
  toolCallId = "permission_decision_1",
  rationale = "test fixture",
) {
  return fakeGatewayToolCall(toolCallId, "permission_decision", {
    risk: decision === "clear" ? "low" : "high",
    decision,
    rationale,
  });
}

export function fakeGatewaySerializedToolCall(
  id: string,
  name: string,
  input: string,
  assistantText?: string,
) {
  return fakeGatewaySse([
    ...(assistantText
      ? [{ type: "text-delta", id: "answer_1", delta: assistantText }]
      : []),
    {
      type: "tool-call",
      toolCallId: id,
      toolName: name,
      input,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

export function fakeGatewayFinalText(text: string) {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 3 },
        outputTokens: { total: 5 },
      },
    },
  ]);
}

export function heldFakeGatewayFinalText() {
  const encoder = new TextEncoder();
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  let closed = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let response: Response | undefined;
  let pendingText: string | undefined;

  const stopTimer = () => {
    if (timer) clearInterval(timer);
    timer = undefined;
  };
  const close = () => {
    if (closed) return;
    closed = true;
    stopTimer();
    controller?.close();
  };
  const finish = (text: string) => {
    if (closed) return;
    if (!controller) {
      pendingText = text;
      return;
    }
    stopTimer();
    controller.enqueue(encoder.encode(
      `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n` +
        `data: ${JSON.stringify({
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
          usage: {
            inputTokens: { total: 3 },
            outputTokens: { total: 5 },
          },
        })}\n\ndata: [DONE]\n\n`,
    ));
    close();
  };
  const createResponse = () => new Response(
    new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        if (closed) {
          value.close();
          return;
        }
        const keepAlive = () => {
          if (!closed) value.enqueue(encoder.encode(": hold-response\n\n"));
        };
        keepAlive();
        timer = setInterval(keepAlive, 50);
        if (pendingText !== undefined) finish(pendingText);
      },
      cancel() {
        closed = true;
        stopTimer();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
  return {
    get response() {
      response ??= createResponse();
      return response;
    },
    release: finish,
    dispose: close,
  };
}

export type FakeGatewayResponse =
  | Response
  | ((body: string) => Response | Promise<Response>);

export type FakeGatewayModel = {
  id: string;
  type?: string;
  owned_by?: string;
  released?: number;
  tags?: string[];
  context_window?: number;
  max_tokens?: number;
  pricing?: Record<string, unknown>;
  reasoning_options?: Array<{
    type: string;
    values?: string[];
    [key: string]: unknown;
  }>;
  fast_options?: Array<{
    type: string;
    [key: string]: unknown;
  }>;
};

export type FakeGatewayModelRequest = {
  headers: Headers;
  url: string;
};

export type FakeGatewayOptions = {
  models?:
    | FakeGatewayModel[]
    | ((request: Request) =>
      | FakeGatewayModel[]
      | Response
      | Promise<FakeGatewayModel[] | Response>);
  classifierDecision?: "clear" | "caution";
  classifierResponses?: FakeGatewayResponse[];
  generationResponse?: (
    generationId: string,
    request: Request,
  ) => Response | Promise<Response>;
};

function serveFakeGateway(
  nextCompletion: (body: string) => Response | Promise<Response>,
  options: FakeGatewayOptions,
) {
  const requests: Array<{ body: string; headers: Headers }> = [];
  const classifierRequests: Array<{ body: string; headers: Headers }> = [];
  const classifierResponses = [...(options.classifierResponses ?? [])];
  const modelRequests: FakeGatewayModelRequest[] = [];
  const generationRequests: string[] = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      if (new URL(req.url).pathname === "/coding-agent/v1/models") {
        modelRequests.push({ headers: new Headers(req.headers), url: req.url });
        const models = typeof options.models === "function"
          ? await options.models(req)
          : options.models;
        if (models instanceof Response) return models;
        return Response.json({
          data: models ?? [{
            id: FAKE_GATEWAY_MODEL,
            type: "language",
            tags: ["tool-use"],
          }],
        });
      }
      if (req.method === "GET" && new URL(req.url).pathname === "/v1/generation") {
        const generationId = new URL(req.url).searchParams.get("id") ?? "";
        generationRequests.push(generationId);
        if (options.generationResponse) {
          return options.generationResponse(generationId, req);
        }
        return new Response("not found", { status: 404 });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      const headers = new Headers(req.headers);
      if (body.includes("\"permission_decision\"")) {
        classifierRequests.push({ body, headers });
        const next = classifierResponses.shift();
        if (next) return typeof next === "function" ? await next(body) : next;
        return fakeGatewayPermissionDecision(options.classifierDecision ?? "clear");
      }
      requests.push({ body, headers });
      return nextCompletion(body);
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    requests,
    classifierRequests,
    generationRequests,
    modelRequests,
    requestCount() {
      return requests.length;
    },
    stop() {
      server.stop(true);
    },
  };
}

export function startFakeGateway(
  responses: FakeGatewayResponse[],
  options: FakeGatewayOptions = {},
) {
  return serveFakeGateway(async (body) => {
    const next = responses.shift();
    if (!next) {
      return new Response("unexpected request", { status: 500 });
    }
    return typeof next === "function" ? await next(body) : next;
  }, options);
}

// Same server and classifier handling as startFakeGateway, but every
// completion request is answered by the supplied callback instead of a
// finite queue. For suites that replay one response indefinitely or switch
// on their own state.
export function startDynamicFakeGateway(
  response: (body: string) => Response | Promise<Response>,
  options: FakeGatewayOptions = {},
) {
  return serveFakeGateway(response, options);
}

export class TmuxSession {
  readonly name: string;
  private readonly socketName?: string;
  private readonly exitStatusPath: string;
  private killed = false;

  private constructor(name: string, exitStatusPath: string, socketName?: string) {
    this.name = name;
    this.exitStatusPath = exitStatusPath;
    this.socketName = socketName;
  }

  static async create(opts?: {
    cmd?: string;
    cwd?: string;
    env?: Record<string, string | undefined>;
    width?: number;
    height?: number;
    stderrPath?: string;
    remainOnExit?: boolean;
    minimumHistoryLines?: number;
    startupWaitMs?: number;
    isolated?: boolean;
    socketName?: string;
  }): Promise<TmuxSession> {
    const {
      cmd = FX_BIN,
      cwd = REPO_ROOT,
      env: requestedEnv = {},
      width = 120,
      height = 40,
      stderrPath,
      remainOnExit = false,
      minimumHistoryLines,
      startupWaitMs = 1000,
      isolated = false,
      socketName,
    } = opts ?? {};
    const env = providerVersionTestEnv(requestedEnv);

    if (
      minimumHistoryLines !== undefined &&
      (!Number.isInteger(minimumHistoryLines) || minimumHistoryLines < 0)
    ) {
      throw new Error(
        `minimumHistoryLines must be a non-negative integer, got ${minimumHistoryLines}`,
      );
    }

    const sequence = ++sessionCounter;
    const name = `fx-test-${process.pid}-${sequence}`;
    const resolvedSocketName = socketName ?? (isolated
      ? `fx-e2e-${process.pid}-${sequence}-${Date.now()}`
      : undefined);
    const startGate = `${name}-start`;
    const exitStatusPath = join(tmpdir(), `${name}.exit-status`);
    rmSync(exitStatusPath, { force: true });

    const authEnvKeys = new Set<string>(AUTH_ENV_KEYS);
    const unsetArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined ? ["-u", shellQuote(key)] : []
    );
    const defaultUnsetArgs = DEFAULT_UNSET_ENV_KEYS.flatMap((key) =>
      Object.prototype.hasOwnProperty.call(env, key) ? [] : ["-u", shellQuote(key)]
    );
    const assignmentArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined || authEnvKeys.has(key) ? [] : [shellQuote(`${key}=${value}`)]
    );
    const sessionEnvArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined || !authEnvKeys.has(key) ? [] : ["-e", `${key}=${value}`]
    );
    const mirroredEnv = MIRRORED_ENV_KEYS.flatMap((key) =>
      Object.prototype.hasOwnProperty.call(env, key)
        ? []
        : [[key, process.env[key]] as const]
    );
    const mirroredUnsetArgs = mirroredEnv.flatMap(([key, value]) =>
      value === undefined ? ["-u", shellQuote(key)] : []
    );
    const mirroredAssignmentArgs = mirroredEnv.flatMap(([key, value]) =>
      value === undefined ? [] : [shellQuote(`${key}=${value}`)]
    );
    const defaultArgs = [
      ["FX_DISABLE_KEYCHAIN", "1"],
      ["FX_SKIP_ONBOARDING", "1"],
      ["FX_SOUND", "0"],
    ].flatMap(([key, value]) =>
      Object.prototype.hasOwnProperty.call(env, key) ? [] : [shellQuote(`${key}=${value}`)]
    );
    const envArgs = [
      ...unsetArgs,
      ...mirroredUnsetArgs,
      ...defaultUnsetArgs,
      ...defaultArgs,
      ...mirroredAssignmentArgs,
      ...assignmentArgs,
    ];
    const envStr = envArgs.length > 0 ? `/usr/bin/env ${envArgs.join(" ")}` : "";
    const command = envStr ? `${envStr} ${cmd}` : cmd;
    const observedCmd = buildObservedCommand(
      command,
      stderrPath,
      exitStatusPath,
    );
    const processEnv = {
      ...process.env,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_SOUND: process.env.FX_SOUND ?? "0",
    };
    for (const key of DEFAULT_UNSET_ENV_KEYS) delete processEnv[key];

    const gatedLaunch = remainOnExit || minimumHistoryLines !== undefined;
    const tmuxCommand = gatedLaunch
      ? `tmux wait-for ${shellQuote(startGate)} && exec ${observedCmd}`
      : observedCmd;
    const tmuxPrefix = resolvedSocketName ? ["-L", resolvedSocketName] : [];
    const setupSessionName = `${name}-setup`;
    const killSetupSession = () => {
      try {
        execFileSync(
          "tmux",
          [...tmuxPrefix, "kill-session", "-t", setupSessionName],
          { stdio: "pipe", env: processEnv },
        );
      } catch {}
    };
    let serverHistoryLines: number | undefined;
    if (minimumHistoryLines !== undefined) {
      execFileSync(
        "tmux",
        [
          ...tmuxPrefix,
          "new-session",
          "-d",
          "-s",
          setupSessionName,
          "sleep 60",
        ],
        { env: processEnv, stdio: "pipe" },
      );
      try {
        const value = execFileSync(
          "tmux",
          [
            ...tmuxPrefix,
            "show-options",
            "-gv",
            "history-limit",
          ],
          { encoding: "utf8", env: processEnv, stdio: ["ignore", "pipe", "pipe"] },
        ).trim();
        const parsed = Number.parseInt(value, 10);
        if (!Number.isSafeInteger(parsed) || parsed < 0) {
          throw new Error(`invalid tmux history limit: ${JSON.stringify(value)}`);
        }
        serverHistoryLines = parsed;
      } catch (err) {
        killSetupSession();
        throw err;
      }
    }
    const launchPrefix = minimumHistoryLines === undefined
      ? tmuxPrefix
      : [
        ...tmuxPrefix,
        "set-option",
        "-g",
        "history-limit",
        String(Math.max(serverHistoryLines!, minimumHistoryLines)),
        ";",
      ];
    const launchSuffix = minimumHistoryLines === undefined
      ? []
      : [
        ";",
        "set-option",
        "-w",
        "-t",
        `${name}:0`,
        "history-limit",
        String(Math.max(serverHistoryLines!, minimumHistoryLines)),
        ";",
        "set-option",
        "-g",
        "history-limit",
        String(serverHistoryLines!),
        ";",
        "kill-session",
        "-t",
        setupSessionName,
      ];
    try {
      execFileSync(
        "tmux",
        [
          ...launchPrefix,
          "new-session",
          "-d",
          "-s",
          name,
          "-x",
          String(width),
          "-y",
          String(height),
          ...sessionEnvArgs,
          tmuxCommand,
          ...launchSuffix,
        ],
        { cwd, stdio: "pipe", env: processEnv },
      );
    } catch (err) {
      if (minimumHistoryLines !== undefined) {
        try {
          execFileSync(
            "tmux",
            [
              ...tmuxPrefix,
              "set-option",
              "-g",
              "history-limit",
              String(serverHistoryLines!),
            ],
            { stdio: "pipe", env: processEnv },
          );
        } catch {}
        try {
          execFileSync("tmux", [...tmuxPrefix, "kill-session", "-t", name], {
            stdio: "pipe",
            env: processEnv,
          });
        } catch {}
        killSetupSession();
        if (String(err).includes("value is")) {
          throw new Error(
            `tmux history limit ${serverHistoryLines} is below required minimum ${minimumHistoryLines}`,
            { cause: err },
          );
        }
      }
      rmSync(exitStatusPath, { force: true });
      throw err;
    }
    const session = new TmuxSession(name, exitStatusPath, resolvedSocketName);
    try {
      for (const key of AUTH_ENV_KEYS) {
        try {
          execFileSync(
            "tmux",
            [...tmuxPrefix, "set-environment", "-u", "-t", name, key],
            { env: processEnv, stdio: "pipe" },
          );
        } catch (err) {
          if (session.isAlive()) throw err;
        }
      }
      if (remainOnExit) {
        execFileSync(
          "tmux",
          [...tmuxPrefix, "set-option", "-w", "-t", `${name}:0`, "remain-on-exit", "on"],
          { stdio: "pipe" },
        );
        const value = execFileSync(
          "tmux",
          [...tmuxPrefix, "show-options", "-w", "-v", "-t", `${name}:0`, "remain-on-exit"],
          { stdio: "pipe", encoding: "utf-8" },
        ).trim();
        if (value !== "on") {
          throw new Error(
            `tmux remain-on-exit verification failed for ${name}: ${JSON.stringify(value)}`,
          );
        }
      }

      if (minimumHistoryLines !== undefined) {
        const inherited = session.historyLimit();
        if (inherited < minimumHistoryLines) {
          throw new Error(
            `tmux history limit ${inherited} is below required minimum ${minimumHistoryLines}`,
          );
        }
      }

      if (gatedLaunch) {
        execFileSync("tmux", [...tmuxPrefix, "wait-for", "-S", startGate], {
          stdio: "pipe",
        });
      }
      await sleep(startupWaitMs);
      return session;
    } catch (err) {
      await session.kill();
      throw err;
    }
  }

  async sendKeys(keys: string): Promise<void> {
    execSync(`${this.tmuxCommand()} send-keys -t ${this.name} ${keys}`, {
      stdio: "pipe",
    });
    await sleep(100);
  }

  sendKeysImmediate(keys: readonly string[]): void {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, ...keys]),
      { stdio: "pipe" },
    );
  }

  sendRepeatedKeyThenImmediate(key: string, count: number, nextKey: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs([
        "send-keys",
        "-N",
        String(count),
        "-t",
        this.name,
        key,
        ";",
        "send-keys",
        "-t",
        this.name,
        nextKey,
      ]),
      { stdio: "pipe" },
    );
  }

  sendLiteralImmediate(text: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, "-l", "--", text]),
      { stdio: "pipe" },
    );
  }

  async sendLiteral(text: string): Promise<void> {
    await this.sendLiteralText(text);
  }

  async sendText(text: string): Promise<void> {
    await this.sendLiteralText(text);
    await this.sendKeys("Enter");
  }

  async pasteText(text: string): Promise<void> {
    const buffer = `${this.name}-paste`;
    execFileSync("tmux", this.tmuxArgs(["load-buffer", "-b", buffer, "-"]), {
      input: text,
      stdio: ["pipe", "pipe", "pipe"],
    });
    execFileSync(
      "tmux",
      this.tmuxArgs(["paste-buffer", "-d", "-p", "-b", buffer, "-t", this.name]),
      { stdio: "pipe" },
    );
    await sleep(250);
  }

  async sendLiteralText(text: string): Promise<void> {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, "-l", "--", text]),
      { stdio: "pipe" },
    );
    await sleep(50);
  }

  async sendHexBytes(hexBytes: readonly string[]): Promise<void> {
    for (let offset = 0; offset < hexBytes.length; offset += TMUX_HEX_CHUNK_BYTES) {
      execFileSync(
        "tmux",
        this.tmuxArgs([
          "send-keys",
          "-t",
          this.name,
          "-H",
          ...hexBytes.slice(offset, offset + TMUX_HEX_CHUNK_BYTES),
        ]),
        { stdio: "pipe" },
      );
    }
    await sleep(150);
  }

  async sendFragmentedHexBytes(
    hexBytes: readonly string[],
    delayMs: number,
    injectionLogPath: string,
  ): Promise<void> {
    if (!Number.isInteger(delayMs) || delayMs < 0) {
      throw new Error(`delayMs must be a non-negative integer, got ${delayMs}`);
    }
    writeFileSync(
      injectionLogPath,
      hexBytes.map((byte, index) =>
        `write=${index + 1}/${hexBytes.length} byte=${byte} delay_before_ms=${index === 0 ? 0 : delayMs}`
      ).join("\n") + "\n",
    );
    for (const [index, byte] of hexBytes.entries()) {
      execFileSync("tmux", this.tmuxArgs(["send-keys", "-t", this.name, "-H", byte]), {
        stdio: "pipe",
      });
      if (index + 1 < hexBytes.length) await sleep(delayMs);
    }
    await sleep(150);
  }

  async capturePane(): Promise<string> {
    try {
      return execSync(`${this.tmuxCommand()} capture-pane -t ${this.name} -p`, {
        stdio: "pipe",
        encoding: "utf-8",
        maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
      });
    } catch {
      return "";
    }
  }

  async captureFullScrollback(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["capture-pane", "-t", this.name, "-p", "-S", "-"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
          maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
        },
      );
    } catch {
      return "";
    }
  }

  /**
   * Complete pane history including the ANSI sequences emitted by fx.
   * Keep this separate from the viewport capture so transcript-order tests
   * inspect all committed output rather than only the visible rows.
   */
  async captureFullScrollbackEscapes(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["capture-pane", "-t", this.name, "-e", "-p", "-S", "-"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
          maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
        },
      );
    } catch {
      return "";
    }
  }

  /**
   * Current pane title, which is what a terminal renders as the tab label.
   * fx sets it through OSC 2, so this reads back what the user would see.
   */
  async paneTitle(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["display-message", "-p", "-t", this.name, "#{pane_title}"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
        },
      ).trimEnd();
    } catch {
      return "";
    }
  }

  /**
   * Resize the tmux window. Delivers a real SIGWINCH to fx, exercising the
   * resize pipeline end-to-end. Default post-resize sleep covers the 100 ms
   * debounce in src/main.zig.
   */
  async resizeWindow(cols: number, rows: number, settleMs = 250): Promise<void> {
    execSync(`${this.tmuxCommand()} resize-window -t ${this.name} -x ${cols} -y ${rows}`, {
      stdio: "pipe",
    });
    await sleep(settleMs);
  }

  /**
   * Capture pane output including raw ANSI escape sequences. Use when you
   * need to assert on color/style or confirm specific escapes were emitted.
   */
  async capturePaneEscapes(): Promise<string> {
    try {
      return execSync(`${this.tmuxCommand()} capture-pane -t ${this.name} -e -p -J`, {
        stdio: "pipe",
        encoding: "utf-8",
        maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
      });
    } catch {
      return "";
    }
  }

  /**
   * Copy subsequent raw pane output to a file. Unlike capture-pane, this
   * preserves control bytes such as BEL before tmux applies them to its grid.
   */
  startPaneOutputCapture(path: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs([
        "pipe-pane",
        "-O",
        "-t",
        this.name,
        `cat >> ${shellQuote(path)}`,
      ]),
      { stdio: "pipe" },
    );
  }

  /**
   * Grid snapshot of the pane as an array of row strings (ANSI stripped).
   * Rows are right-padded to the pane width so positional assertions are
   * stable.
   */
  async capturePaneGrid(): Promise<string[]> {
    const raw = await this.capturePane();
    if (raw.length === 0) return [];
    return raw.replace(/\n$/, "").split("\n");
  }

  /**
   * Full snapshot for golden-style assertions.
   */
  async snapshot(): Promise<{ grid: string[]; escapes: string; alive: boolean }> {
    return {
      grid: await this.capturePaneGrid(),
      escapes: await this.capturePaneEscapes(),
      alive: this.isAlive(),
    };
  }

  /**
   * Current pane dimensions as tmux sees them. Handy for sanity checks after
   * resizeWindow().
   */
  paneSize(): { cols: number; rows: number } {
    const raw = execSync(
      `${this.tmuxCommand()} display-message -t ${this.name} -p "#{pane_width}x#{pane_height}"`,
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const [cols, rows] = raw.split("x").map((s) => parseInt(s, 10));
    return { cols, rows };
  }

  panePid(): number {
    const raw = execFileSync(
      "tmux",
      this.tmuxArgs([
        "display-message",
        "-t",
        `${this.name}:0.0`,
        "-p",
        "#{pane_pid}",
      ]),
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const value = Number.parseInt(raw, 10);
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new Error(`Invalid tmux pane PID: ${JSON.stringify(raw)}`);
    }
    return value;
  }

  processPid(): number {
    const panePid = this.panePid();
    let children = "";
    try {
      children = execFileSync("pgrep", ["-P", String(panePid)], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch {}
    return parseSingleChildPid(children, panePid);
  }

  historyLimit(): number {
    const raw = execFileSync(
      "tmux",
      this.tmuxArgs([
        "display-message",
        "-t",
        this.name,
        "-p",
        "#{history_limit}",
      ]),
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const value = Number.parseInt(raw, 10);
    if (!Number.isInteger(value) || value < 0) {
      throw new Error(`Invalid tmux history limit: ${JSON.stringify(raw)}`);
    }
    return value;
  }

  paneStatus(): { dead: boolean; status: number | null } {
    try {
      const raw = execSync(
        `${this.tmuxCommand()} display-message -t ${this.name}:0.0 -p "#{pane_dead}:#{pane_dead_status}"`,
        { stdio: "pipe", encoding: "utf-8" },
      ).trim();
      const [dead, status] = raw.split(":");
      const parsed = status && status.length > 0 ? parseInt(status, 10) : null;
      const parsedStatus = parsed !== null &&
          Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= 255
        ? parsed
        : null;
      return {
        dead: dead === "1",
        status: dead === "1" && parsedStatus === null
          ? this.recordedExitStatus()
          : parsedStatus,
      };
    } catch {
      return { dead: true, status: this.recordedExitStatus() };
    }
  }

  isPaneAlive(): boolean {
    return !this.paneStatus().dead;
  }

  cursorPosition(): { row: number; col: number } {
    const raw = execSync(
      `${this.tmuxCommand()} display-message -t ${this.name} -p "#{cursor_y} #{cursor_x}"`,
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const values = raw.split(/\s+/).map((value) => Number.parseInt(value, 10));
    if (
      values.length !== 2 ||
      !Number.isInteger(values[0]) ||
      !Number.isInteger(values[1]) ||
      values[0] < 0 ||
      values[1] < 0
    ) {
      throw new Error(`Invalid tmux cursor position: ${JSON.stringify(raw)}`);
    }
    const [row, col] = values;
    return { row, col };
  }

  async waitForCursor(
    predicate: (position: { row: number; col: number }) => boolean,
    timeoutMs = 3_000,
  ): Promise<{ row: number; col: number }> {
    const start = Date.now();
    let lastMatch = "";
    let lastObserved: { row: number; col: number } | null = null;
    let stableMatches = 0;
    while (Date.now() - start < timeoutMs) {
      const position = this.cursorPosition();
      lastObserved = position;
      const key = `${position.row}:${position.col}`;
      if (predicate(position)) {
        stableMatches = key === lastMatch ? stableMatches + 1 : 1;
        lastMatch = key;
        if (stableMatches >= 2) return position;
      } else {
        lastMatch = "";
        stableMatches = 0;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for cursor predicate in ${this.name}; last=${JSON.stringify(lastObserved)}`,
    );
  }

  async waitForPane(
    predicate: (pane: string) => boolean,
    timeoutMs = 3_000,
  ): Promise<string> {
    const start = Date.now();
    let lastPane = "";
    while (Date.now() - start < timeoutMs) {
      const pane = await this.capturePane();
      lastPane = pane;
      if (predicate(pane)) return pane;
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for pane predicate in ${this.name}.\nLast pane:\n${lastPane}`,
    );
  }

  async waitForStableGrid(
    expected: string[],
    normalize: (grid: string[]) => string[] = (grid) => grid,
    timeoutMs = 3_000,
  ): Promise<string[]> {
    const normalizedExpected = normalize(expected);
    const deadline = Date.now() + timeoutMs;
    let latest: string[] = [];
    while (Date.now() < deadline) {
      latest = await this.capturePaneGrid();
      const normalizedLatest = normalize(latest);
      if (normalizedLatest.length === normalizedExpected.length &&
          normalizedLatest.every((line, index) => line === normalizedExpected[index])) {
        return latest;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable terminal grid.\nExpected:\n${expected.join("\n")}\nActual:\n${latest.join("\n")}`,
    );
  }

  async waitForText(
    pattern: string | RegExp,
    timeoutMs = 15_000,
  ): Promise<string> {
    return this.waitForPane(
      (pane) => typeof pattern === "string"
        ? pane.includes(pattern)
        : pattern.test(pane),
      timeoutMs,
    );
  }

  async waitForComposer(timeoutMs = 15_000): Promise<string> {
    return this.waitForPane(hasEmptyComposer, timeoutMs);
  }

  async waitForStableComposer(
    timeoutMs = 15_000,
    stableMs = 100,
  ): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    let stableSince: number | null = null;
    let previousPane = "";
    let lastPane = "";
    while (Date.now() < deadline) {
      const pane = await this.capturePane();
      lastPane = pane;
      if (hasEmptyComposer(pane)) {
        if (pane !== previousPane) {
          previousPane = pane;
          stableSince = Date.now();
        } else if (stableSince !== null && Date.now() - stableSince >= stableMs) {
          return pane;
        }
      } else {
        previousPane = "";
        stableSince = null;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable composer in ${this.name}.\nLast pane:\n${lastPane}`,
    );
  }

  async waitForStableScrollback(
    predicate: (scrollback: string) => boolean,
    timeoutMs = 15_000,
    stableMs = 100,
  ): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    let stableSince: number | null = null;
    let previousScrollback = "";
    let lastScrollback = "";
    while (Date.now() < deadline) {
      const scrollback = await this.captureFullScrollback();
      lastScrollback = scrollback;
      if (predicate(scrollback)) {
        if (scrollback !== previousScrollback) {
          previousScrollback = scrollback;
          stableSince = Date.now();
        } else if (stableSince !== null && Date.now() - stableSince >= stableMs) {
          return scrollback;
        }
      } else {
        previousScrollback = "";
        stableSince = null;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable scrollback in ${this.name}.\nLast scrollback:\n${lastScrollback}`,
    );
  }

  async waitForSessionEnd(timeoutMs = 10_000): Promise<boolean> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (!this.isAlive()) return true;
      await sleep(500);
    }
    const pane = await this.capturePane();
    throw new Error(
      `Timed out waiting for tmux session ${this.name} to exit after ${timeoutMs}ms.\nLast pane:\n${pane}`,
    );
  }

  isAlive(): boolean {
    try {
      execSync(`${this.tmuxCommand()} has-session -t ${this.name}`, { stdio: "pipe" });
      return true;
    } catch {
      return false;
    }
  }

  async kill(): Promise<void> {
    if (this.killed) return;
    this.killed = true;
    try {
      execSync(`${this.tmuxCommand()} kill-session -t ${this.name}`, { stdio: "pipe" });
    } catch {}

    const deadline = Date.now() + 1_000;
    let missingServerChecks = 0;
    while (Date.now() < deadline) {
      try {
        execFileSync(
          "tmux",
          this.tmuxArgs(["list-sessions", "-F", "#{session_name}"]),
          { stdio: "pipe" },
        );
        break;
      } catch {
        missingServerChecks += 1;
        if (missingServerChecks === 2) break;
        await sleep(25);
      }
    }
    rmSync(this.exitStatusPath, { force: true });
  }

  private recordedExitStatus(): number | null {
    try {
      const value = Number.parseInt(readFileSync(this.exitStatusPath, "utf8").trim(), 10);
      return Number.isSafeInteger(value) && value >= 0 && value <= 255 ? value : null;
    } catch {
      return null;
    }
  }

  private tmuxArgs(args: string[]): string[] {
    return this.socketName ? ["-L", this.socketName, ...args] : args;
  }

  private tmuxCommand(): string {
    return this.socketName
      ? `tmux -L ${shellQuote(this.socketName)}`
      : "tmux";
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function tmuxAvailable(): boolean {
  try {
    execSync("tmux -V", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}
