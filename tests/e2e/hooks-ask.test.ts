import { afterEach, describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN, runFx } from "../evals/eval-helpers";
import { processGroupAlive } from "./process-alive";
import { childExited, makeFifo, pidWritten, untilChange, untilWritersGone } from "./hooks-helpers";
import { waitForRootTurnCommitted } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  startFakeGateway,
  type FakeGatewayResponse,
} from "./tmux-helpers";

// Hooks inside a real `fx ask` turn against a fake model. Each test checks what fx sent to the
// model (the request bodies) and what it did (files on disk), not internal state.

const TIMEOUT = 60_000;
const DENY_REASON = "no shell here";
const BLOCK_REASON = "blocked by policy";
const CONTEXT_MARK = "CTX-MARK-7";
const POST_CONTEXT_MARK = "POST-MARK-5";
const START_CONTEXT_MARK = "START-MARK-9";
const STOP_REASON = "KEEP-GOING-3";
const CHILD_START_MARK = "CHILD-CTX-3";
const CHILD_DENY_REASON = "no shell in children";
const CHILD_GO_ON = "CHILD-GO-ON";

const cleanups: string[] = [];

afterEach(() => {
  for (const top of cleanups.splice(0)) cleanupIsolatedTestHome(top);
});

type Root = {
  home: string;
  workspace: string;
  marker: string;
  hookRan: string;
};

// HOME holds the profile's settings; the workspace holds the project hook file.
function createRoot(settings: Record<string, unknown>): Root {
  const top = realpathSync(createIsolatedTestHome());
  cleanups.push(top);
  const home = join(top, "home");
  const workspace = join(top, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(join(workspace, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(settings));
  const realWorkspace = realpathSync(workspace);
  return {
    home,
    workspace: realWorkspace,
    marker: join(realWorkspace, "ran-marker"),
    hookRan: join(realWorkspace, "hook-ran"),
  };
}

function writeProjectHooks(root: Root, hooks: object) {
  writeFileSync(join(root.workspace, ".fx", "hooks.json"), JSON.stringify(hooks));
}

// Trusts the workspace's project hooks, as a person does with `fx hook trust --all`. fx ask runs only
// trusted hooks, so a test that expects a hook to run trusts it before the run.
async function trustProjectHooks(root: Root) {
  if (!existsSync(join(root.workspace, ".fx", "hooks.json"))) return;
  const result = await runFx(["hook", "trust", "--all"], {
    cwd: root.workspace,
    env: { HOME: root.home, AI_AGENT: undefined, FX_AUTO_UPGRADE: "0", FX_SOUND: "0" },
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
}

function lineCount(path: string): number {
  return readFileSync(path, "utf8").split("\n").filter((line) => line.length > 0).length;
}

// A PreToolUse hook for the shell tool. It leaves a marker when it runs, so a test can tell
// that the hook ran, and then refuses the call.
function denyShellHooks(hookRan: string) {
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: "shell",
          hooks: [{ type: "command", command: `touch '${hookRan}'; echo '${DENY_REASON}' >&2; exit 2` }],
        },
      ],
    },
  };
}

function addContextHooks() {
  const output = JSON.stringify({
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: CONTEXT_MARK },
  });
  return {
    hooks: {
      UserPromptSubmit: [{ hooks: [{ type: "command", command: `printf '%s' '${output}'` }] }],
    },
  };
}

function blockPromptHooks() {
  return {
    hooks: {
      UserPromptSubmit: [
        { hooks: [{ type: "command", command: `echo '${BLOCK_REASON}' >&2; exit 2` }] },
      ],
    },
  };
}

// A Stop hook that asks for one more round on its first run only. The count file records
// each run, so the test can check how many times the hook ran.
function stopOnceHooks(countFile: string) {
  const block = JSON.stringify({ decision: "block", reason: STOP_REASON });
  return {
    hooks: {
      Stop: [
        {
          hooks: [
            {
              type: "command",
              command: `if [ ! -s '${countFile}' ]; then printf '%s' '${block}'; fi; echo run >> '${countFile}'`,
            },
          ],
        },
      ],
    },
  };
}

function postToolContextHooks() {
  const output = JSON.stringify({
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: POST_CONTEXT_MARK },
  });
  return {
    hooks: {
      PostToolUse: [
        { matcher: "shell", hooks: [{ type: "command", command: `printf '%s' '${output}'` }] },
      ],
    },
  };
}

function sessionStartHooks(countFile: string) {
  const output = JSON.stringify({
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: START_CONTEXT_MARK },
  });
  return {
    hooks: {
      SessionStart: [
        {
          hooks: [{ type: "command", command: `echo start >> '${countFile}'; printf '%s' '${output}'` }],
        },
      ],
    },
  };
}

// A PreToolUse hook that fails (exit 1, not 2) with a named id. fx must go on with the call.
function failOpenHooks() {
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: "shell",
          hooks: [{ type: "command", command: "echo oops >&2; exit 1", id: "fail-open" }],
        },
      ],
    },
  };
}

// A PreToolUse hook that answers "allow" for the shell tool.
function allowShellHooks() {
  const output = JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "ok by hook",
    },
  });
  return {
    hooks: {
      PreToolUse: [
        { matcher: "shell", hooks: [{ type: "command", command: `printf '%s' '${output}'` }] },
      ],
    },
  };
}

type AskJson = {
  exit_code: number;
  output: string;
  final_output: string;
  session_id: string;
  error?: string;
  tool_calls: Array<{ name: string; status: string }>;
};

function askJson(stdout: string): AskJson {
  return JSON.parse(stdout.trim()) as AskJson;
}

// Runs `fx ask --json` against a fake model. By default it runs with --yolo, so the shell tool
// runs without a prompt and only a hook can stop a call. Returns the process result, every model
// request body, and the count of review requests, all read before the gateway stops.
async function ask(
  root: Root,
  prompt: string,
  responses: FakeGatewayResponse[],
  flags: string[] = ["--yolo", "--no-save"],
) {
  return runAsk(root, prompt, startFakeGateway(responses), flags);
}

// The same, with a gateway that answers each request by its body, so a subagent's requests get
// their own answers.
async function askWith(
  root: Root,
  prompt: string,
  answer: (body: string) => Response | Promise<Response>,
  flags: string[] = ["--yolo"],
) {
  return runAsk(root, prompt, startDynamicFakeGateway(answer), flags);
}

async function runAsk(
  root: Root,
  prompt: string,
  gateway: ReturnType<typeof startFakeGateway>,
  flags: string[],
  trust = true,
) {
  try {
    if (trust) await trustProjectHooks(root);
    const result = await runFx(["ask", "--json", ...flags, prompt], {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: "fake-hooks-ask-key",
        VERCEL_OIDC_TOKEN: undefined,
        AI_AGENT: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TEST_GATEWAY_CREDITS_URL: undefined,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
      },
      timeoutMs: TIMEOUT,
    });
    return {
      result,
      bodies: gateway.requests.map((request) => request.body),
      classifierRequests: gateway.classifierRequests.length,
    };
  } finally {
    gateway.stop();
  }
}

describe("fx ask with hooks", () => {
  test("a PreToolUse hook denies a shell call, and the model sees the reason", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, denyShellHooks(root.hookRan));

    const { result, bodies } = await ask(root, "Create the marker with the shell tool.", [
      fakeShellRun("shell_deny_1", `touch '${root.marker}'`),
      fakeGatewayFinalText("the shell call was refused"),
    ]);

    expect(result.code).toBe(0);
    expect(existsSync(root.hookRan)).toBe(true);
    expect(existsSync(root.marker)).toBe(false);
    expect(bodies).toHaveLength(2);
    expect(bodies[1]).toContain(DENY_REASON);
    const out = askJson(result.stdout);
    expect(out.exit_code).toBe(0);
    // The deny is a warning notice for the person reading the JSON; the hook has no id, so its default id is a hash.
    expect(out.notices).toEqual([
      {
        topic: "hooks",
        tone: "warning",
        text: expect.stringMatching(new RegExp(`^Hook [0-9a-f]{12} blocked shell: ${DENY_REASON}$`)),
      },
    ]);
    expect(out.output).toContain("the shell call was refused");
    expect(out.tool_calls).toContainEqual(expect.objectContaining({ name: "shell", status: "error" }));
  });

  test("a deny reason with an ESC sequence reaches stderr as visible text, and the model still gets the raw bytes", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    // printf writes an ESC sequence to stderr, and that is the reason the hook gives for the deny.
    writeProjectHooks(root, {
      hooks: {
        PreToolUse: [
          {
            matcher: "shell",
            hooks: [
              {
                type: "command",
                command: `touch '${root.hookRan}'; printf '\\033[31m%s\\033[0m' '${DENY_REASON}' >&2; exit 2`,
              },
            ],
          },
        ],
      },
    });

    const { result, bodies } = await ask(root, "Create the marker with the shell tool.", [
      fakeShellRun("shell_esc_1", `touch '${root.marker}'`),
      fakeGatewayFinalText("the shell call was refused"),
    ]);

    expect(result.code).toBe(0);
    expect(existsSync(root.marker)).toBe(false);
    // The person's stderr shows the sequence as text, with no raw ESC byte (R4.6).
    expect(result.stderr).toContain(`\\x1b[31m${DENY_REASON}\\x1b[0m`);
    expect(result.stderr).not.toContain("\x1b");
    // The model's request carries the reason with its raw bytes, JSON-escaped as \u001b (R4.6: model text is not escaped).
    expect(bodies[1]).toContain(`\\u001b[31m${DENY_REASON}`);
  });

  test("an untrusted project PreToolUse hook does not run in fx ask, and runs once fx hook trust trusts it", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, denyShellHooks(root.hookRan));

    // The hook waits for trust, so it does not run: the shell call runs and the model gets no refusal.
    const waiting = await runAsk(
      root,
      "Create the marker with the shell tool.",
      startFakeGateway([
        fakeShellRun("shell_wait_1", `touch '${root.marker}'`),
        fakeGatewayFinalText("the shell call ran"),
      ]),
      ["--yolo", "--no-save"],
      false,
    );
    expect(waiting.result.code).toBe(0);
    expect(existsSync(root.hookRan)).toBe(false);
    expect(existsSync(root.marker)).toBe(true);
    expect(waiting.bodies).toHaveLength(2);
    expect(waiting.bodies[1]).not.toContain(DENY_REASON);
    expect(askJson(waiting.result.stdout).tool_calls).toContainEqual(
      expect.objectContaining({ name: "shell", status: "success" }),
    );

    // After a person trusts the hook, the same hook runs and refuses the call.
    rmSync(root.marker, { force: true });
    await trustProjectHooks(root);
    const trusted = await runAsk(
      root,
      "Create the marker with the shell tool.",
      startFakeGateway([
        fakeShellRun("shell_trust_1", `touch '${root.marker}'`),
        fakeGatewayFinalText("the shell call was refused"),
      ]),
      ["--yolo", "--no-save"],
      false,
    );
    expect(trusted.result.code).toBe(0);
    expect(existsSync(root.hookRan)).toBe(true);
    expect(existsSync(root.marker)).toBe(false);
    expect(trusted.bodies[1]).toContain(DENY_REASON);
  });

  test("a UserPromptSubmit hook adds context to the first request", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, addContextHooks());

    const { result, bodies } = await ask(root, "Say hello.", [fakeGatewayFinalText("hello")]);

    expect(result.code).toBe(0);
    expect(bodies.length).toBeGreaterThanOrEqual(1);
    expect(bodies[0]).toContain(CONTEXT_MARK);
  });

  test("a UserPromptSubmit context stays in the resumed turn's request, right after the prompt", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, addContextHooks());

    // `ask` defaults to --no-save, which leaves no session to resume, so this run saves.
    const first = await ask(root, "Say hello.", [fakeGatewayFinalText("hello")], ["--yolo"]);
    expect(first.result.code, first.result.stderr).toBe(0);
    const sessionId = (JSON.parse(first.result.stdout.trim()) as { session_id: string }).session_id;
    const live = JSON.parse(first.bodies[first.bodies.length - 1]!) as { prompt: unknown[] };

    const resumed = await ask(root, "And now?", [fakeGatewayFinalText("again")], ["--yolo", "--resume", sessionId]);
    expect(resumed.result.code, resumed.result.stderr).toBe(0);
    expect(resumed.bodies.length).toBe(1);
    const next = JSON.parse(resumed.bodies[0]!) as { prompt: unknown[] };

    // Provider prompt caching depends on the resumed request starting with exactly the bytes the live turn last sent.
    const livePrompt = live.prompt.map((message) => JSON.stringify(message));
    const nextPrompt = next.prompt.map((message) => JSON.stringify(message));
    expect(livePrompt.join("")).toContain(CONTEXT_MARK);
    expect(nextPrompt.slice(0, livePrompt.length)).toEqual(livePrompt);
  });

  test("a UserPromptSubmit hook can block the prompt", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, blockPromptHooks());

    const { result, bodies } = await ask(root, "Say hello.", [fakeGatewayFinalText("never sent")]);

    expect(bodies).toHaveLength(0);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain(`[notice] A hook blocked this prompt: ${BLOCK_REASON}`);
    const out = askJson(result.stdout);
    expect(out.exit_code).toBe(1);
    expect(out.output).toBe("");
    expect(out.tool_calls).toEqual([]);
    expect(out.notices).toEqual([
      { topic: "hooks", tone: "warning", text: `A hook blocked this prompt: ${BLOCK_REASON}` },
    ]);
  });

  test("with experimental.hooks off, no hook runs", async () => {
    const root = createRoot({});
    writeProjectHooks(root, denyShellHooks(root.hookRan));

    const { result, bodies } = await ask(root, "Create the marker with the shell tool.", [
      fakeShellRun("shell_off_1", `touch '${root.marker}'`),
      fakeGatewayFinalText("the shell call ran"),
    ]);

    expect(result.code).toBe(0);
    expect(existsSync(root.marker)).toBe(true);
    expect(existsSync(root.hookRan)).toBe(false);
    expect(bodies).toHaveLength(2);
    expect(bodies[1]).not.toContain(DENY_REASON);
    const out = askJson(result.stdout);
    expect(out.tool_calls).toContainEqual(expect.objectContaining({ name: "shell", status: "success" }));
  });

  test("a Stop hook makes the turn go on once", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    const countFile = join(root.workspace, "stop-count");
    writeProjectHooks(root, stopOnceHooks(countFile));

    const { result, bodies } = await ask(root, "Say hi.", [
      fakeGatewayFinalText("first answer"),
      fakeGatewayFinalText("second answer"),
    ]);

    expect(result.code).toBe(0);
    expect(bodies).toHaveLength(2);
    expect(bodies[1]).toContain(STOP_REASON);
    expect(lineCount(countFile)).toBe(2);
    // final_output is the turn's reply text, so the continuation's answer comes last.
    const out = askJson(result.stdout);
    expect(out.final_output).toContain("first answer");
    expect(out.final_output.endsWith("second answer")).toBe(true);
  });

  test("a PostToolUse hook adds context after a tool", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, postToolContextHooks());

    const { result, bodies } = await ask(root, "Run echo.", [
      fakeShellRun("shell_post_1", "echo hi"),
      fakeGatewayFinalText("done"),
    ]);

    expect(result.code).toBe(0);
    expect(bodies).toHaveLength(2);
    expect(bodies[1]).toContain(POST_CONTEXT_MARK);
    const out = askJson(result.stdout);
    expect(out.tool_calls).toContainEqual(expect.objectContaining({ name: "shell", status: "success" }));
  });

  test("a SessionStart hook adds context once", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    const countFile = join(root.workspace, "start-count");
    writeProjectHooks(root, sessionStartHooks(countFile));

    // Without --no-save, so the turn has a saved session and its start hooks run.
    const { result, bodies } = await ask(
      root,
      "Run echo.",
      [fakeShellRun("shell_start_1", "echo hi"), fakeGatewayFinalText("done")],
      ["--yolo"],
    );

    expect(result.code).toBe(0);
    expect(bodies).toHaveLength(2);
    for (const body of bodies) expect(body).toContain(START_CONTEXT_MARK);
    expect(lineCount(countFile)).toBe(1);
    expect(askJson(result.stdout).session_id).not.toBe("");
  });

  test("a failing hook does not stop the call", async () => {
    const root = createRoot({ experimental: { hooks: true } });
    writeProjectHooks(root, failOpenHooks());

    const { result } = await ask(root, "Create the marker with the shell tool.", [
      fakeShellRun("shell_fail_1", `touch '${root.marker}'`),
      fakeGatewayFinalText("after the failing hook"),
    ]);

    expect(result.code).toBe(0);
    expect(existsSync(root.marker)).toBe(true);
    expect(result.stderr).toContain("[notice] Hook fail-open failed: exited with code 1: oops");
    const out = askJson(result.stdout);
    expect(out.exit_code).toBe(0);
    const warnings = out.notices.filter(
      (notice: { topic: string; tone: string }) => notice.topic === "hooks" && notice.tone === "warning",
    );
    expect(warnings).toHaveLength(1);
    expect(warnings[0].text).toContain("fail-open");
  });

  test("a hook allow lets a call run that would need permission", async () => {
    // ask mode with no prompter: a call that needs approval is refused, not sent for review.
    const settings = { permission_mode: "ask", experimental: { hooks: true } };

    const refused = createRoot(settings);
    const refusedRun = await ask(
      refused,
      "Create the marker with the shell tool.",
      [fakeShellRun("shell_perm_1", `touch '${refused.marker}'`), fakeGatewayFinalText("never reached")],
      ["--no-save"],
    );
    expect(refusedRun.result.code).toBe(1);
    expect(existsSync(refused.marker)).toBe(false);
    expect(refusedRun.bodies).toHaveLength(1);
    expect(refusedRun.classifierRequests).toBe(0);
    expect(askJson(refusedRun.result.stdout).error).toBe("NonInteractivePermissionRequired");

    const allowed = createRoot(settings);
    writeProjectHooks(allowed, allowShellHooks());
    const allowedRun = await ask(
      allowed,
      "Create the marker with the shell tool.",
      [fakeShellRun("shell_perm_2", `touch '${allowed.marker}'`), fakeGatewayFinalText("allowed")],
      ["--no-save"],
    );
    expect(allowedRun.result.code).toBe(0);
    expect(existsSync(allowed.marker)).toBe(true);
    expect(allowedRun.bodies).toHaveLength(2);
    expect(allowedRun.classifierRequests).toBe(0);
    expect(askJson(allowedRun.result.stdout).tool_calls).toContainEqual(
      expect.objectContaining({ name: "shell", status: "success" }),
    );
  });
});

// Starts `fx ask --json` as `runAsk` does, without waiting for it, so a test can signal fx while it runs.
function spawnAsk(root: Root, prompt: string, gateway: ReturnType<typeof startFakeGateway>): ChildProcess {
  const overrides: Record<string, string | undefined> = {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-hooks-ask-key",
    VERCEL_OIDC_TOKEN: undefined,
    AI_AGENT: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CREDITS_URL: undefined,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
  };
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries({ ...process.env, ...overrides })) {
    if (value !== undefined) env[key] = value;
  }
  return nodeSpawn(FX_BIN, ["ask", "--json", "--yolo", "--no-save", prompt], {
    cwd: root.workspace,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

// SIGHUP to fx ask ends fx and the hook's process group with it. A hang-up has no turn to cancel, so it does
// not go through the interrupt that INT and TERM use.
describe("fx ask hang-up with hooks", () => {
  test(
    "SIGHUP ends fx ask and stops the process group of a PreToolUse hook that is running",
    async () => {
      const root = createRoot({ experimental: { hooks: true } });
      const pidFile = join(root.workspace, "hook.pid");
      const fifo = join(root.workspace, "hook.fifo");
      makeFifo(fifo);
      writeProjectHooks(root, {
        hooks: {
          PreToolUse: [
            {
              matcher: "shell",
              hooks: [{ type: "command", id: "sleepy", command: `exec 3> '${fifo}'; echo $$ > '${pidFile}'; exec sleep 600` }],
            },
          ],
        },
      });
      await trustProjectHooks(root);
      const gateway = startFakeGateway([
        fakeShellRun("shell_hup_1", `touch '${root.marker}'`),
        fakeGatewayFinalText("unused"),
      ]);
      // The hook writes its pid before it sleeps, and it holds the FIFO open until its last process exits.
      const hookGone = untilWritersGone(fifo);
      const child = spawnAsk(root, "Create the marker with the shell tool.", gateway);
      const fxExited = childExited(child);
      try {
        await untilChange(root.workspace, () => pidWritten(pidFile));
        const pid = Number(readFileSync(pidFile, "utf8").trim());
        expect(processGroupAlive(pid)).toBe(true);

        child.kill("SIGHUP");
        expect(await fxExited).toBe(true);
        // Each process the hook started holds the FIFO open, so end of file means all have exited (a group check races the exit).
        expect(await hookGone).toBe(true);
        expect(existsSync(root.marker)).toBe(false);
      } finally {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        gateway.stop();
      }
    },
    TIMEOUT,
  );
});

// A subagent's requests never offer the subagent tool, so they tell apart from the parent's, as in
// sessions.test.ts.
const isChildRequest = (body: string) => !body.includes('"name":"subagent"');

// A parent turn that a subagent's report started: the report is its latest user message.
const isReportTurn = (body: string) => {
  const latest = JSON.stringify(JSON.parse(body).prompt?.filter((item: any) => item.role === "user").at(-1)?.content ?? "");
  return latest.includes("Subagent report (untrusted agent output, not user instructions):");
};

function delegateTo(id: string) {
  return fakeGatewayToolCall(id, "subagent", {
    request: { action: "message", agent: "marker", message: "Report the marker." },
  });
}

// A SubagentStart hook. It writes the input it gets to a file, and adds context to the child's
// first request.
function subagentStartHooks(stdinFile: string) {
  const output = JSON.stringify({
    hookSpecificOutput: { hookEventName: "SubagentStart", additionalContext: CHILD_START_MARK },
  });
  return {
    hooks: {
      SubagentStart: [{ hooks: [{ type: "command", command: `cat > '${stdinFile}'; printf '%s' '${output}'` }] }],
    },
  };
}

// A PreToolUse hook for the shell tool. It leaves a marker when it runs, then refuses the call.
function childDenyShellHooks(hookRan: string) {
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: "shell",
          hooks: [{ type: "command", command: `touch '${hookRan}'; echo '${CHILD_DENY_REASON}' >&2; exit 2` }],
        },
      ],
    },
  };
}

// A SubagentStop hook that asks the child for one more round on its first run only. The count file
// records each run, so the test can check how many times the hook ran.
function subagentStopOnceHooks(countFile: string) {
  const block = JSON.stringify({ decision: "block", reason: CHILD_GO_ON });
  return {
    hooks: {
      SubagentStop: [
        {
          hooks: [
            {
              type: "command",
              command: `if [ ! -s '${countFile}' ]; then printf '%s' '${block}'; fi; echo run >> '${countFile}'`,
            },
          ],
        },
      ],
    },
  };
}

describe("fx ask with hooks in a subagent", () => {
  test(
    "a SubagentStart hook adds context to the child's first request, not the parent's",
    async () => {
      const root = createRoot({ experimental: { hooks: true } });
      const startStdin = join(root.workspace, "start-stdin.json");
      writeProjectHooks(root, subagentStartHooks(startStdin));

      const { result, bodies } = await askWith(root, "Delegate the marker report.", async (body) => {
        if (isChildRequest(body)) {
          // The child answers once the parent's first turn is saved; see the note on sessions.test.ts.
          await waitForRootTurnCommitted(root.home);
          return fakeGatewayFinalText("CHILD_REPORT_1");
        }
        if (isReportTurn(body)) return fakeGatewayFinalText("PARENT_DONE_1");
        if (body.includes("delegate-start")) return fakeGatewayFinalText("PARENT_SENT_1");
        return delegateTo("delegate-start");
      });

      expect(result.code).toBe(0);
      const childBodies = bodies.filter(isChildRequest);
      expect(childBodies.length).toBeGreaterThanOrEqual(1);
      expect(childBodies[0]).toContain(CHILD_START_MARK);
      for (const body of bodies.filter((body) => !isChildRequest(body))) {
        expect(body).not.toContain(CHILD_START_MARK);
      }
      expect(askJson(result.stdout).output).toContain("PARENT_DONE_1");

      // The hook's input names the subagent once, as a string, and its surface.
      const input = readFileSync(startStdin, "utf8");
      expect(input.split('"agent_id"').length - 1).toBe(1);
      const parsed = JSON.parse(input);
      expect(typeof parsed.agent_id).toBe("string");
      expect(parsed.fx_surface).toBe("subagent");
      expect(parsed.hook_event_name).toBe("SubagentStart");
    },
    TIMEOUT * 2,
  );

  test(
    "a PreToolUse deny applies inside a subagent",
    async () => {
      const root = createRoot({ experimental: { hooks: true } });
      writeProjectHooks(root, childDenyShellHooks(root.hookRan));
      const childMarker = join(root.workspace, "child-marker");

      const { result, bodies } = await askWith(root, "Delegate the marker report.", async (body) => {
        if (isChildRequest(body)) {
          // The shell call's id comes back in the child's next request, which is its last.
          if (body.includes("child-shell-2")) {
            await waitForRootTurnCommitted(root.home);
            return fakeGatewayFinalText("CHILD_SAW_DENY");
          }
          return fakeShellRun("child-shell-2", `touch '${childMarker}'`);
        }
        if (isReportTurn(body)) return fakeGatewayFinalText("PARENT_DONE_2");
        if (body.includes("delegate-deny")) return fakeGatewayFinalText("PARENT_SENT_2");
        return delegateTo("delegate-deny");
      });

      expect(result.code).toBe(0);
      expect(existsSync(root.hookRan)).toBe(true);
      expect(existsSync(childMarker)).toBe(false);
      const childBodies = bodies.filter(isChildRequest);
      expect(childBodies).toHaveLength(2);
      expect(childBodies[1]).toContain(CHILD_DENY_REASON);
      for (const body of bodies.filter((body) => !isChildRequest(body))) {
        expect(body).not.toContain(CHILD_DENY_REASON);
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a SubagentStop hook makes the child go on once",
    async () => {
      const root = createRoot({ experimental: { hooks: true } });
      const countFile = join(root.workspace, "child-stop-count");
      writeProjectHooks(root, subagentStopOnceHooks(countFile));

      const { result, bodies } = await askWith(root, "Delegate the marker report.", async (body) => {
        if (isChildRequest(body)) {
          await waitForRootTurnCommitted(root.home);
          return fakeGatewayFinalText(body.includes(CHILD_GO_ON) ? "CHILD_DONE_3" : "CHILD_FIRST_3");
        }
        if (isReportTurn(body)) return fakeGatewayFinalText("PARENT_DONE_3");
        if (body.includes("delegate-stop")) return fakeGatewayFinalText("PARENT_SENT_3");
        return delegateTo("delegate-stop");
      });

      expect(result.code).toBe(0);
      const childBodies = bodies.filter(isChildRequest);
      expect(childBodies).toHaveLength(2);
      expect(childBodies[0]).not.toContain(CHILD_GO_ON);
      expect(childBodies[1]).toContain(CHILD_GO_ON);
      expect(lineCount(countFile)).toBe(2);
      // The parent's run finishes normally after the child's report.
      const out = askJson(result.stdout);
      expect(out.exit_code).toBe(0);
      expect(out.output).toContain("PARENT_DONE_3");
    },
    TIMEOUT * 2,
  );
});
