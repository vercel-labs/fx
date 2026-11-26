import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync, type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { basename, join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { type FakeVercelLogEntry, tarEntries } from "./fixtures/fake-vercel-api";
import {
  expectRemoteLoginNeverSent,
  fakeApiToken,
  fakeLoginToken,
  fakeOtherUser,
  fakeSecondTeam,
  fakeTeam,
  fakeUser,
  type RemoteSetupFixture,
  type SetupProject,
  type SetupTeam,
  startRemoteSetupFixture,
} from "./remote-setup-fixture";

// The `runner` field of `shell`. With the sandbox policy on, the shell schema
// advertises it, and a run that names it goes to its placement. The sandbox
// cases use the fake Vercel API, so a refused run shows no exec request in its log.
const TIMEOUT = 60_000;
const HAS_TMUX = tmuxAvailable();

// Every test folder lives under one base folder, which the fake maps to its own folder
// (macRoots), so a command's mkdir and the push agree on one path.
const testBase = realpathSync(mkdtempSync(join(tmpdir(), "fx-runner-e2e-")));

// The built-in runner's login and setup go to one fake Vercel API for this file.
let remoteSetup: RemoteSetupFixture;
beforeAll(() => {
  remoteSetup = startRemoteSetupFixture({ macRoots: [testBase] });
});
afterAll(() => {
  remoteSetup?.stop();
  rmSync(testBase, { recursive: true, force: true });
});

// The `shell` schema a surface advertises, as property names in order.
// `fx ask --no-save` gets the process-only form; the TUI and ACP get the full form.
// The runner field comes last in both when it is on.
const ASK_KEYS = ["action", "command", "cwd", "profile", "yield_time_ms", "timeout_ms", "session_id", "force"];
const FULL_KEYS = [
  "action",
  "command",
  "cwd",
  "profile",
  "shell",
  "tty",
  "yield_time_ms",
  "timeout_ms",
  "reload",
  "session_id",
  "chars",
  "force",
];
const RUNNER_PROPERTY = {
  type: "string",
  enum: ["local", "remote"],
  description: "For run: local (this machine, default) or remote (the user's sandbox).",
};

// The result of `foo` on a run with the runner field off, recorded on the
// binary before the runner field existed. `runner` must give the same result
// with only the name changed.
const FOO_RESULT =
  '{"error":{"code":"invalid_shell_request","executed":false,"problems":["foo is not accepted for run."]}}';

// The refusals of the runner field, with the spec's message for each.
const REFUSAL_PREFIX = "fx did not run this command: ";
const E1 = 'runner must be "local" or "remote"';
const E2_STOP = "runner is not accepted for stop.";
const E3_SHELL = "shell applies only to local runs";
const E3_RELOAD = "reload applies only to local runs";
const E3_PROFILE = "profile applies only to local runs";
const E12 = `${REFUSAL_PREFIX}a tty=true command cannot run in a sandbox. Run it without tty, or change the rule in ~/.fx/sandbox/config.json.`;

type ShellSchema = { properties: Record<string, unknown>; required: string[] };
type Gateway = ReturnType<typeof startFakeGateway>;
type GatewayResponse = Parameters<typeof startFakeGateway>[0][number];
type Profile = { home: string; workspace: string };
type Fixture = Profile & { logStart: number; gateway: Gateway; setup: RemoteSetupFixture };

const homes: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];
const children: ChildProcess[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  // Only processes this file started: the fake sandbox daemon and the ACP server.
  for (const child of children.splice(0)) child.kill("SIGKILL");
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

function createDir(): string {
  const dir = realpathSync(mkdtempSync(join(testBase, "case-")));
  homes.push(dir);
  return dir;
}

function createProfile(sandboxOn: boolean): Profile {
  const home = createDir();
  const workspace = createDir();
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { sandbox_execution: sandboxOn } }));
  return { home, workspace };
}

function gatewayEnv(home: string, gateway: Gateway): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-runner-key",
    VERCEL_OIDC_TOKEN: undefined,
    VERCEL_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function shellSchemaFrom(body: string): ShellSchema | undefined {
  const tools = (JSON.parse(body) as { tools?: Array<{ name: string; inputSchema?: ShellSchema }> }).tools ?? [];
  return tools.find(({ name }) => name === "shell")?.inputSchema;
}

async function firstShellSchema(gateway: Gateway): Promise<ShellSchema> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    for (const request of gateway.requests) {
      const schema = shellSchemaFrom(request.body);
      if (schema) return schema;
    }
    await Bun.sleep(100);
  }
  throw new Error("no gateway request advertised the shell tool");
}

function expectShellSchema(schema: ShellSchema, keys: string[], runnerOn: boolean): void {
  expect(schema.required).toEqual(["action"]);
  if (!runnerOn) {
    expect(Object.keys(schema.properties)).toEqual(keys);
    expect(schema.properties).not.toHaveProperty("runner");
    return;
  }
  expect(Object.keys(schema.properties)).toEqual([...keys, "runner"]);
  expect(schema.properties.runner).toEqual(RUNNER_PROPERTY);
}

// The tool result texts in one request body, in order.
function toolResultsIn(body: string): string[] {
  const texts: string[] = [];
  const parsed = JSON.parse(body) as { prompt?: Array<{ content: unknown }> };
  for (const message of parsed.prompt ?? []) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type !== "tool-result") continue;
      const output = part.output as { value?: unknown };
      texts.push(typeof output?.value === "string" ? output.value : JSON.stringify(output));
    }
  }
  return texts;
}

// Every distinct tool result text fx sent back to the model, in order. Each
// request carries the whole history, so a result is listed once.
function toolResults(gateway: Gateway): string[] {
  const results: string[] = [];
  for (const request of gateway.requests.slice(1)) {
    for (const text of toolResultsIn(request.body)) {
      if (!results.includes(text)) results.push(text);
    }
  }
  return results;
}

// The number of tool calls whose result the model received with this text.
// `toolResults` drops a repeated text, so two refused calls count once there.
function callsWithResult(gateway: Gateway, text: string): number {
  const byCall = new Map<string, string>();
  for (const request of gateway.requests.slice(1)) {
    const parsed = JSON.parse(request.body) as { prompt?: Array<{ content: unknown }> };
    for (const message of parsed.prompt ?? []) {
      if (!Array.isArray(message.content)) continue;
      for (const part of message.content as Array<Record<string, unknown>>) {
        if (part.type !== "tool-result") continue;
        const output = part.output as { value?: unknown };
        byCall.set(String(part.toolCallId), typeof output?.value === "string" ? output.value : JSON.stringify(output));
      }
    }
  }
  return [...byCall.values()].filter((value) => value === text).length;
}

// Every tool result text fx sent back to the model, in order.
function toolTexts(gateway: Gateway): string {
  return toolResults(gateway).join("\n");
}

// The session ID of the first shell result in a request body, to poll that run.
function runSessionId(body: string): string {
  for (const text of toolResultsIn(body)) {
    if (!text.startsWith("{")) continue;
    const sessionId = (JSON.parse(text) as { session_id?: string }).session_id;
    if (sessionId) return sessionId;
  }
  throw new Error("the shell result has no session_id");
}

async function askShellSchema(runnerOn: boolean): Promise<ShellSchema> {
  const { home, workspace } = createProfile(runnerOn);
  const gateway = startFakeGateway([fakeGatewayFinalText("Schema checked.\n")]);
  gateways.push(gateway);
  const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Show the shell schema."], {
    cwd: workspace,
    env: gatewayEnv(home, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  return firstShellSchema(gateway);
}

async function tuiShellSchema(runnerOn: boolean): Promise<ShellSchema> {
  const { home, workspace } = createProfile(runnerOn);
  const gateway = startFakeGateway([fakeGatewayFinalText("Schema checked.\n"), fakeGatewayFinalText("Schema checked.\n")]);
  gateways.push(gateway);
  const session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: workspace,
    env: gatewayEnv(home, gateway),
    width: 112,
    height: 32,
    stderrPath: join(home, "stderr.log"),
    startupWaitMs: 0,
  });
  sessions.push(session);
  await session.waitForComposer(TIMEOUT);
  await session.sendText("Show the shell schema.");
  return firstShellSchema(gateway);
}

// The text fx sent back for one shell call, with the runner field off or on.
async function askShellResult(sandboxOn: boolean, input: object): Promise<string> {
  const { home, workspace } = createProfile(sandboxOn);
  const gateway = startFakeGateway([fakeGatewayToolCall("call-1", "shell", input), fakeGatewayFinalText("done\n")]);
  gateways.push(gateway);
  const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Run it."], {
    cwd: workspace,
    env: gatewayEnv(home, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  return toolTexts(gateway);
}

// ---- the sandbox fixture, as sandbox-provider.test.ts builds it ----

function git(cwd: string, args: string[]) {
  execFileSync("git", ["-c", "commit.gpgsign=false", ...args], {
    cwd,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "fx test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "fx test",
      GIT_COMMITTER_EMAIL: "test@example.com",
    },
    stdio: "ignore",
  });
}

// A repository with one commit, a sandbox config whose provider is the fake
// CLI, and the sandbox on. The model's responses are `responses`.
// `config` adds to the sandbox config, given the repo path: rules and folder defaults.
async function withSandboxFixture(
  responses: GatewayResponse[] | Parameters<typeof startDynamicFakeGateway>[0],
  body: (fixture: Fixture) => Promise<void>,
  config: (repo: string) => object = () => ({}),
  sandboxOn = true,
  setup?: RemoteSetupFixture,
  homeViaLink = false,
) {
  const root = createDir();
  const home = join(root, "home");
  const repo = join(root, "repo");
  // The fake maps this root's Mac paths to its own folder, so a command's mkdir and the
  // push agree on one path. A test that brings its own setup keeps it.
  const ownSetup = setup ? undefined : startRemoteSetupFixture({ macRoots: [realpathSync(root)] });
  const active = setup ?? ownSetup!;
  // HOME is a symlink to the real folder, as macOS reaches $TMPDIR through /var.
  if (homeViaLink) {
    mkdirSync(join(root, "real-home"));
    symlinkSync(join(root, "real-home"), home);
  }
  mkdirSync(join(home, ".fx", "sandbox"), { recursive: true });
  mkdirSync(repo);
  writeFileSync(join(repo, "a.txt"), "hello\n");
  git(repo, ["init", "-q"]);
  git(repo, ["add", "a.txt"]);
  git(repo, ["commit", "-q", "-m", "initial"]);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { sandbox_execution: sandboxOn } }));
  writeFileSync(
    join(home, ".fx", "sandbox", "config.json"),
    JSON.stringify({
      rules: [],
      remote: active.remote,
      ...config(repo),
    }),
  );
  const gateway = Array.isArray(responses) ? startFakeGateway(responses) : startDynamicFakeGateway(responses);
  gateways.push(gateway);
  try {
    await body({ home, workspace: realpathSync(repo), gateway, setup: active, logStart: active.api.log.length });
    if (ownSetup) checkLoginWhenSignedIn(ownSetup.api);
  } finally {
    ownSetup?.stop();
  }
}

// Once per fake: a fake that signed in saw only the test token, never the login. A fake
// that never signed in has no login to check.
function checkLoginWhenSignedIn(api: RemoteSetupFixture["api"]) {
  if (api.log.some((entry) => entry.route === "user")) expectRemoteLoginNeverSent(api);
}

// The fake Vercel API's requests made since this fixture started. The API is shared by
// the file, so a fixture reads only its own entries.
function apiSince(fixture: Fixture) {
  return fixture.setup.api.log.slice(fixture.logStart);
}

// This fixture's exec commands, as the fake saw them: a start for each, and an exit
// once it ended.
function events(fixture: Fixture): Array<Record<string, unknown>> {
  const ids = new Set(apiSince(fixture).filter((entry) => entry.route === "cmd" && entry.kind === "exec").map((entry) => entry.commandId));
  const out: Array<Record<string, unknown>> = [];
  for (const command of fixture.setup.api.commands()) {
    if (!ids.has(command.id)) continue;
    out.push({ ev: "start", id: command.id, argv: command.args });
    if (command.status !== "running") out.push({ ev: "exit", id: command.id, code: command.exitCode });
  }
  return out;
}

// The requests that mean a command reached the sandbox or ran in it: a sandbox create,
// or an exec command.
function execEvents(fixture: Fixture): Array<Record<string, unknown>> {
  return apiSince(fixture).filter((entry) => entry.route === "createSandbox" || (entry.route === "cmd" && entry.kind === "exec"));
}

// One fx ask in the sandbox fixture. The model's responses already carry the call.
async function askSandbox(fixture: Fixture): Promise<string> {
  const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
    cwd: fixture.workspace,
    timeoutMs: TIMEOUT,
    env: { ...gatewayEnv(fixture.home, fixture.gateway), ...fixture.setup.env },
  });
  expect(result.code).toBe(0);
  return toolTexts(fixture.gateway);
}

// A tool call whose arguments are the raw JSON text given, as a provider sends
// them: a string. An object input would be re-encoded by the gateway parser,
// which rejects a duplicate key before the tool sees it.
function fakeGatewayRawToolCall(id: string, name: string, rawInput: string): Response {
  const call = JSON.stringify({ type: "tool-call", toolCallId: id, toolName: name, input: rawInput });
  const finish = JSON.stringify({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
  return new Response(`data: ${call}\n\ndata: ${finish}\n\ndata: [DONE]\n\n`, {
    headers: { "content-type": "text/event-stream" },
  });
}

// A shell call whose input is built when the model asks, so it can name the
// fixture's workspace, which exists only once the fixture has started.
function shellCallAt(input: () => object): GatewayResponse[] {
  return [(_body: string) => fakeGatewayToolCall("call-1", "shell", input()), fakeGatewayFinalText("done\n")];
}

function cwdRefusal(workspace: string): string {
  return `${REFUSAL_PREFIX}a remote run needs a cwd inside the workspace ${workspace}.`;
}

function shellCall(input: object): GatewayResponse[] {
  return [fakeGatewayToolCall("call-1", "shell", input), fakeGatewayFinalText("done\n")];
}

// ---- ACP over stdio, one JSON-RPC request at a time ----

function acpClient(proc: ChildProcess) {
  const pending = new Map<number, (message: any) => void>();
  let buffer = "";
  proc.stdout!.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const message = JSON.parse(line) as { id?: number; method?: string };
      if (message.method === undefined && typeof message.id === "number" && pending.has(message.id)) {
        pending.get(message.id)!(message);
        pending.delete(message.id);
      }
    }
  });
  let nextId = 1;
  return {
    request(method: string, params: object): Promise<any> {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`ACP ${method} timed out`)), TIMEOUT);
        pending.set(id, (message) => {
          clearTimeout(timer);
          resolve(message.result ?? message.error ?? message);
        });
        proc.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });
    },
  };
}

// ---- the cases ----

describe("fx ask advertises the shell runner field only with sandbox execution on", () => {
  test("setting off: the process-only shell schema has no runner field", async () => {
    expectShellSchema(await askShellSchema(false), ASK_KEYS, false);
  }, TIMEOUT * 2);

  test("setting on: the process-only shell schema adds runner with local and remote", async () => {
    expectShellSchema(await askShellSchema(true), ASK_KEYS, true);
  }, TIMEOUT * 2);
});

describe("the TUI advertises the shell runner field only with sandbox execution on", () => {
  test.skipIf(!HAS_TMUX)("setting off: the shell schema has no runner field", async () => {
    expectShellSchema(await tuiShellSchema(false), FULL_KEYS, false);
  }, TIMEOUT * 2);

  test.skipIf(!HAS_TMUX)("setting on: the shell schema adds runner with local and remote", async () => {
    expectShellSchema(await tuiShellSchema(true), FULL_KEYS, true);
  }, TIMEOUT * 2);
});

describe("ACP advertises the shell runner field only with sandbox execution on", () => {
  test("setting on: the first request of an ACP session has runner in shell", async () => {
    const { home, workspace } = createProfile(true);
    const gateway = startFakeGateway([fakeGatewayFinalText("Schema checked.\n"), fakeGatewayFinalText("Schema checked.\n")]);
    gateways.push(gateway);
    const proc = spawn(FX_BIN, ["acp"], { cwd: workspace, env: gatewayEnv(home, gateway), stdio: ["pipe", "pipe", "pipe"] });
    children.push(proc);
    const client = acpClient(proc);
    await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    const created = (await client.request("session/new", { cwd: workspace, mcpServers: [] })) as { sessionId: string };
    await client.request("session/prompt", {
      sessionId: created.sessionId,
      prompt: [{ type: "text", text: "Show the shell schema." }],
    });
    const schema = await firstShellSchema(gateway);
    expect(Object.keys(schema.properties)).toEqual([...FULL_KEYS, "runner"]);
    expect(schema.properties.runner).toEqual(RUNNER_PROPERTY);
  }, TIMEOUT * 2);
});

describe("with the runner field off, runner is an unknown field, as foo is", () => {
  test("the result of runner is the result of foo with only the name changed", async () => {
    expect(await askShellResult(false, { action: "run", command: "true", foo: "remote" })).toBe(FOO_RESULT);
    expect(await askShellResult(false, { action: "run", command: "true", runner: "remote" })).toBe(
      FOO_RESULT.replace("foo", "runner"),
    );
  }, TIMEOUT * 2);
});

// ---- Phase 2 attacks: each case names what it expects and checks what happened ----

describe("phase 2 attacks on the runner field", () => {
  test("attack 1: runner values that are not local or remote are refused, and nothing runs", async () => {
    for (const value of ["REMOTE", " remote", "", 1, ["remote"], { x: 1 }]) {
      await withSandboxFixture(shellCall({ action: "run", command: "touch made.txt", runner: value }), async (fixture) => {
        expect(await askSandbox(fixture)).toContain(E1);
        expect(execEvents(fixture)).toEqual([]);
        expect(existsSync(join(fixture.workspace, "made.txt"))).toBe(false);
      });
    }
  }, TIMEOUT * 8);

  test("attack 1 null: a null runner is read as absent, so the run is local", async () => {
    await withSandboxFixture(shellCall({ action: "run", command: "touch made.txt", runner: null }), async (fixture) => {
      const text = await askSandbox(fixture);
      expect(text).not.toContain(E1);
      expect(text).toContain('"state":"completed"');
      expect(existsSync(join(fixture.workspace, "made.txt"))).toBe(true);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("attack 2: a duplicate runner key is rejected before the shell tool reads it, in both orders", async () => {
    for (const raw of [
      '{"action":"run","command":"echo hi","runner":"local","runner":"remote"}',
      '{"action":"run","command":"echo hi","runner":"remote","runner":"local"}',
    ]) {
      await withSandboxFixture(
        [fakeGatewayRawToolCall("call-1", "shell", raw), fakeGatewayFinalText("done\n")],
        async (fixture) => {
          const text = await askSandbox(fixture);
          expect(text).toContain("Tool arguments repeated an object key");
          expect(text).not.toContain("output_delta");
          expect(execEvents(fixture)).toEqual([]);
        },
        () => ({ rules: [{ command: "echo*", runner: "local" }] }),
      );
    }
  }, TIMEOUT * 4);

  test("attack 3: a remote cwd that leaves the workspace is refused, and the root itself is not", async () => {
    const cases: Array<{ cwd: (root: string) => string; refused: boolean }> = [
      { cwd: () => "../outside", refused: true },
      { cwd: () => "sub/../../outside", refused: true },
      { cwd: (root) => root, refused: false },
      { cwd: (root) => `${root}/`, refused: false },
    ];
    for (const { cwd, refused } of cases) {
      let root = "";
      await withSandboxFixture(
        shellCallAt(() => ({ command: "echo hi", runner: "remote", cwd: cwd(root) })),
        async (fixture) => {
          root = fixture.workspace;
          mkdirSync(join(fixture.workspace, "..", "outside"), { recursive: true });
          mkdirSync(join(fixture.workspace, "sub"), { recursive: true });
          const text = await askSandbox(fixture);
          if (refused) {
            expect(text).toContain(cwdRefusal(fixture.workspace));
            expect(execEvents(fixture)).toEqual([]);
          } else {
            expect(text).not.toContain("cwd inside");
            expect(text).toContain("hi");
            expect(execEvents(fixture).length).toBeGreaterThan(0);
          }
        },
      );
    }
  }, TIMEOUT * 8);

  test("attack 3 symlink: a link inside the root that points outside is refused, and never runs locally", async () => {
    await withSandboxFixture(
      shellCallAt(() => ({ command: "echo hi", runner: "remote", cwd: "link" })),
      async (fixture) => {
        mkdirSync(join(fixture.workspace, "..", "outside"), { recursive: true });
        symlinkSync(join(fixture.workspace, "..", "outside"), join(fixture.workspace, "link"));
        // Recorded: resolveCwd refuses the link before placement, with its own
        // message, so the E13 text is not used here. Nothing runs.
        expect(await askSandbox(fixture)).toBe("shell run cwd is invalid: PathOutsideWorkspace");
        expect(execEvents(fixture)).toEqual([]);
      },
    );
  }, TIMEOUT * 2);

  test("attack 4: runner local with a rule that picks remote runs remote, and the line says so", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "local" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("hi");
        expect(execEvents(fixture).length).toBeGreaterThan(0);
        expect(text.endsWith('"notice":"fx: ran on remote because of your rule for echo*"}')).toBe(true);
      },
      () => ({ rules: [{ command: "echo*", runner: "remote" }] }),
    );
  }, TIMEOUT * 2);

  test("attack 5a: runner remote with tty and no rule is refused as E12, and nothing runs", async () => {
    await withSandboxFixture(shellCall({ command: "echo hi", runner: "remote", tty: true }), async (fixture) => {
      expect(await askSandbox(fixture)).toBe(E12);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("attack 5b: runner remote with tty and a local rule runs locally, and the first result has the line", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "remote", tty: true }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("hi");
        expect(text.endsWith('"notice":"fx: ran on local because of your rule for echo*"}')).toBe(true);
        expect(execEvents(fixture)).toEqual([]);
      },
      () => ({ rules: [{ command: "echo*", runner: "local" }] }),
    );
  }, TIMEOUT * 2);

  test("attack 6: runner remote on a run with no command gives the result a run with no command gives", async () => {
    let withRunner = "";
    let without = "";
    await withSandboxFixture(shellCall({ action: "run", runner: "remote" }), async (fixture) => {
      withRunner = await askSandbox(fixture);
      expect(execEvents(fixture)).toEqual([]);
    });
    await withSandboxFixture(shellCall({ action: "run" }), async (fixture) => {
      without = await askSandbox(fixture);
      expect(execEvents(fixture)).toEqual([]);
    });
    expect(withRunner).toBe(without);
  }, TIMEOUT * 4);

  test("attack 7: a subagent child's first request has runner in shell when the switch is on", async () => {
    const { home, workspace } = createProfile(true);
    const childBodies: string[] = [];
    const gateway = startDynamicFakeGateway((body) => {
      if (!body.includes('"name":"subagent"')) {
        childBodies.push(body);
        return fakeGatewayFinalText("child done\n");
      }
      if (body.includes("call-sub")) return fakeGatewayFinalText("delegated\n");
      return fakeGatewayToolCall("call-sub", "subagent", {
        action: "message",
        agent: "reviewer",
        message: "Check the shell schema.",
        report: "final",
      });
    });
    gateways.push(gateway);
    const result = await runFx(["ask", "--json", "--yolo", "Delegate a check."], {
      cwd: workspace,
      env: gatewayEnv(home, gateway),
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(0);
    expect(childBodies.length).toBeGreaterThan(0);
    const schema = shellSchemaFrom(childBodies[0]);
    expect(schema?.properties.runner).toEqual(RUNNER_PROPERTY);
    // A child gets the full shell schema, as it did before the runner work: its
    // projection never used the process-only variant. Only `runner` is new.
    expect(Object.keys(schema?.properties ?? {})).toEqual([
      "action",
      "command",
      "cwd",
      "profile",
      "shell",
      "tty",
      "yield_time_ms",
      "timeout_ms",
      "reload",
      "session_id",
      "chars",
      "force",
      "runner",
    ]);
  }, TIMEOUT * 2);

  test("attack 8: with the switch off, runner remote and a rule that places remote are refused as unknown, and nothing is placed", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "remote" }),
      async (fixture) => {
        expect(await askSandbox(fixture)).toBe(
          '{"error":{"code":"invalid_shell_request","executed":false,"problems":["runner is not accepted for run."]}}',
        );
        expect(events(fixture)).toEqual([]);
      },
      () => ({ rules: [{ command: "echo*", runner: "remote" }] }),
      false,
    );
  }, TIMEOUT * 2);
});

describe("a home folder reached through a symlink still runs commands (the fx home is resolved)", () => {
  test("a remote run goes through the sandbox", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo linked-remote", runner: "remote" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("linked-remote");
        expect(text).not.toContain("fx did not run");
        expect(execEvents(fixture).length).toBeGreaterThan(0);
      },
      () => ({}),
      true,
      undefined,
      true,
    );
  }, TIMEOUT * 2);

  test("a local command is not refused", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo linked-local" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("linked-local");
        expect(text).not.toContain("fx did not run");
        expect(execEvents(fixture)).toEqual([]);
      },
      () => ({}),
      true,
      undefined,
      true,
    );
  }, TIMEOUT * 2);
});

describe("a run that goes somewhere other than the request says why (D2, D3, D7)", () => {
  test("D3: a rule that picks local adds its line last, and nothing reaches the sandbox", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "remote" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("hi");
        expect(text.endsWith('"notice":"fx: ran on local because of your rule for echo*"}')).toBe(true);
        expect(text.match(/fx: ran/g)).toHaveLength(1);
        expect(execEvents(fixture)).toEqual([]);
      },
      () => ({ rules: [{ command: "echo*", runner: "local" }] }),
    );
  }, TIMEOUT * 2);

  test("D2: an isolated folder default adds the floor line, and the run goes through the sandbox", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "local" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("hi");
        expect(text.endsWith(`"notice":"fx: ran isolated because of your folder rule for ${fixture.workspace}"}`)).toBe(true);
        expect(execEvents(fixture).length).toBeGreaterThan(0);
      },
      (repo) => ({ workspaces: { [repo]: "isolated" } }),
    );
  }, TIMEOUT * 2);

  test("no line when the request already matches the rule's target", async () => {
    await withSandboxFixture(
      shellCall({ command: "echo hi", runner: "local" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("hi");
        expect(text).not.toContain("fx: ran");
        expect(execEvents(fixture)).toEqual([]);
      },
      () => ({ rules: [{ command: "echo*", runner: "local" }] }),
    );
  }, TIMEOUT * 2);

  test("AC-2: setting on with no rules, a call without runner runs locally: local output, no notice, and no request to the fake API", async () => {
    await withSandboxFixture(shellCall({ command: "echo local-output" }), async (fixture) => {
      const text = await askSandbox(fixture);
      expect(text).toContain("local-output");
      expect(text).not.toContain('"notice":');
      expect(text).not.toContain("fx: ran");
      expect(apiSince(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("AC-4: a rule for local sets local outside an isolated folder; inside it the floor wins, and a cwd outside is E13", async () => {
    // Elsewhere: the rule alone picks local. The command is echo, not make, so no real build runs here.
    await withSandboxFixture(
      shellCall({ command: "echo deploy-docs", runner: "remote" }),
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text).toContain("deploy-docs");
        expect(text.match(/fx: ran on local because of your rule for echo deploy\*/g)).toHaveLength(1);
        expect(execEvents(fixture)).toEqual([]);
      },
      () => ({ rules: [{ command: "echo deploy*", runner: "local" }] }),
    );
    // In the isolated folder the floor is a boundary: a local request runs isolated, and a cwd outside is refused.
    const outside = createDir();
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", { command: "ls", runner: "local" }),
        fakeGatewayToolCall("call-2", "shell", { command: "ls", runner: "local", cwd: outside }),
        fakeGatewayFinalText("done\n"),
      ],
      async (fixture) => {
        const text = await askSandbox(fixture);
        expect(text.match(/fx: ran isolated because of your folder rule for /g)).toHaveLength(1);
        expect(text.match(/needs a cwd inside the workspace/g)).toHaveLength(1);
        expect(execEvents(fixture).length).toBeGreaterThan(0);
      },
      (repo) => ({ rules: [{ command: "echo deploy*", runner: "local" }], workspaces: { [repo]: "isolated" } }),
    );
  }, TIMEOUT * 4);

  test("a background run gets the line on its first result, and the poll that finishes it does not", async () => {
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", {
          action: "run",
          command: "sleep 2; echo done",
          runner: "remote",
          yield_time_ms: 200,
        }),
        (body: string) =>
          fakeGatewayToolCall("call-2", "shell", {
            action: "interact",
            session_id: runSessionId(body),
            yield_time_ms: 10_000,
          }),
        fakeGatewayFinalText("done\n"),
      ],
      async (fixture) => {
        await askSandbox(fixture);
        const results = toolResults(fixture.gateway);
        expect(results[0]).toContain('"state":"running"');
        expect(results[0].endsWith('"notice":"fx: ran on local because of your rule for sleep*"}')).toBe(true);
        expect(results[1]).toContain("done");
        expect(results[1]).not.toContain("fx: ran");
      },
      () => ({ rules: [{ command: "sleep*", runner: "local" }] }),
    );
  }, TIMEOUT * 2);
});

// ---- remote setup: the prompts, the refusals and the first run (spec AC-5 to AC-7, AC-18, AC-20, AC-25, AC-30) ----

// The setup refusals, word for word from src/core/runner/setup_host.zig.
const E5_NO_LOGIN = "fx did not run this command: no Vercel login. Run `vercel login`, then try again.";
const E6_LOGIN_REJECTED =
  "fx did not run this command: the Vercel login has expired or was rejected. Run `vercel whoami` to refresh it, or `vercel login`, then try again.";
const E7_NO_CHANNEL =
  "fx did not run this command: remote is not set up, and fx cannot ask the user here. Ask again in an interactive fx session.";
const E8_DECLINED = "fx did not run this command: the user did not set up remote.";
const E10_SUB_AGENT = "fx did not run this command: remote is not set up. Set it up from the main conversation first.";
const INTERIM_TEXT = "the sandbox provider cannot be used: ";
const P1_MESSAGE = "fx asks: Which Vercel team should remote commands use?";
const NO_REMOTE = (): object => ({ remote: undefined });
// The setup lists, which no model request may carry (AC-5, spec line 370): the ids of
// every team and project the fake sets up, and the names of the team and project that
// the test did not use. The team and project a run used are named in its note (N14),
// so their names are not in this list.
const SETUP_NAMES = [
  "team_fx_test", "prj_fx_test", "team_fx_second", "prj_fx_second",
  "fx-second-team", "fx second team", "fx-second-project",
];

function p2Message(slug: string): string {
  return `fx asks: Pick a project in ${slug}. fx will copy this repository's files to a sandbox in the project you pick, for remote commands.`;
}

async function withSetup(
  options: Parameters<typeof startRemoteSetupFixture>[0],
  body: (setup: RemoteSetupFixture) => Promise<void>,
) {
  const setup = startRemoteSetupFixture({ macRoots: [testBase], ...options });
  try {
    await body(setup);
    checkLoginWhenSignedIn(setup.api);
  } finally {
    setup.stop();
  }
}

function sandboxConfigText(fixture: Fixture): string {
  return readFileSync(join(fixture.home, ".fx", "sandbox", "config.json"), "utf8");
}

function expectRemoteWritten(fixture: Fixture, team: SetupTeam, project: SetupProject, userId: string) {
  const remote = JSON.parse(sandboxConfigText(fixture)).remote;
  expect(remote).toMatchObject({
    team_id: team.id,
    team_slug: team.slug,
    project_id: project.id,
    project_name: project.name,
    user_id: userId,
  });
  expect(typeof remote.confirmed_at).toBe("string");
}

function expectNoInterimText(...texts: string[]) {
  for (const text of texts) expect(text).not.toContain(INTERIM_TEXT);
}

function expectNoSetupNames(gateway: Gateway) {
  const bodies = gateway.requests.map((request) => request.body).join("\n");
  for (const name of SETUP_NAMES) expect(bodies).not.toContain(name);
}

type AcpElicitation = { turn: number; message: string; params: Record<string, any> };
type AcpAnswer = (params: Record<string, any>) => { action: "accept" | "decline" | "cancel"; content?: Record<string, unknown> };

/// The client's answers to the setup prompts: the named team, then the named
/// project. A team prompt is the one with a `team` property.
function answerSetup(team: string, project: string): AcpAnswer {
  return (params) =>
    "team" in (params.requestedSchema?.properties ?? {})
      ? { action: "accept", content: { team } }
      : { action: "accept", content: { project } };
}

/// One `fx acp` process with one session. Each prompt is one turn, and the
/// client answers every `elicitation/create` with `answer` and allows every
/// permission. The fake setup API and the login come from `fixture.setup`.
async function acpRun(
  fixture: Fixture,
  prompts: string[],
  answer: AcpAnswer,
  options: {
    permissionMode?: string;
    // The option id to choose for each permission request, given its params. Default: allow once.
    permissionOption?: (params: Record<string, any>) => string;
  } = {},
): Promise<{ elicitations: AcpElicitation[]; stopReasons: string[]; permissions: Array<Record<string, any>> }> {
  const env: Record<string, string> = {};
  const merged = {
    ...gatewayEnv(fixture.home, fixture.gateway),
    ...fixture.setup.env,
    FX_PERMISSION_MODE: options.permissionMode ?? "full-access",
    PATH: process.env.PATH,
  };
  for (const [key, value] of Object.entries(merged)) if (value !== undefined) env[key] = value;
  const proc = spawn(FX_BIN, ["acp"], { cwd: fixture.workspace, env, stdio: ["pipe", "pipe", "pipe"] });
  children.push(proc);
  const pending = new Map<number, (message: any) => void>();
  const elicitations: AcpElicitation[] = [];
  const stopReasons: string[] = [];
  const permissions: Array<Record<string, any>> = [];
  let turn = 0;
  let nextId = 1;
  let buffer = "";
  const send = (message: object) => proc.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  proc.stdout!.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const message = JSON.parse(line) as { id?: number; method?: string; params?: Record<string, any> };
      if (message.method === undefined && typeof message.id === "number") {
        pending.get(message.id)?.(message);
        pending.delete(message.id);
      } else if (message.method === "elicitation/create" && message.id !== undefined) {
        const params = message.params ?? {};
        elicitations.push({ turn, message: params.message, params });
        send({ id: message.id, result: answer(params) });
      } else if (message.method === "session/request_permission" && message.id !== undefined) {
        const params = message.params ?? {};
        permissions.push(params);
        const optionId = options.permissionOption?.(params) ?? "allow_once";
        send({ id: message.id, result: { outcome: { outcome: "selected", optionId } } });
      }
    }
  });
  const request = (method: string, params: object) =>
    new Promise<any>((resolve, reject) => {
      const id = nextId++;
      const timer = setTimeout(
        () => reject(new Error(`ACP ${method} timed out; elicitations: ${JSON.stringify(elicitations.map((e) => [e.turn, e.message]))}`)),
        TIMEOUT * 3,
      );
      pending.set(id, (message) => {
        clearTimeout(timer);
        resolve(message.result ?? message.error ?? message);
      });
      send({ id, method, params });
    });
  await request("initialize", { protocolVersion: 1, clientCapabilities: { elicitation: { form: {} } } });
  const created = (await request("session/new", { cwd: fixture.workspace, mcpServers: [] })) as { sessionId: string };
  for (const text of prompts) {
    turn += 1;
    const result = (await request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text }] })) as {
      stopReason?: string;
    };
    stopReasons.push(String(result.stopReason));
  }
  proc.stdin!.end();
  return { elicitations, stopReasons, permissions };
}

describe("a command grant names its placement and project (A1, AC-13)", () => {
  test("AC-13: an always grant for a local command does not admit the same command run remote, which asks once", async () => {
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", { command: "echo same-command" }),
        fakeGatewayFinalText("local done\n"),
        fakeGatewayToolCall("call-2", "shell", { command: "echo same-command", runner: "remote" }),
        fakeGatewayFinalText("remote done\n"),
      ],
      async (fixture) => {
        const rawInputOf = (params: Record<string, any>) => JSON.stringify(params.toolCall?.rawInput ?? {});
        const run = await acpRun(fixture, ["Run it here.", "Run it remote."], () => "", {
          permissionMode: "ask",
          permissionOption: (params) => (rawInputOf(params).includes('"runner"') ? "allow_once" : "allow_always"),
        });
        // The local command asked once, and its always grant did not admit the remote run: that run asked too.
        expect(run.permissions).toHaveLength(2);
        expect(rawInputOf(run.permissions[0]!)).not.toContain('"runner"');
        expect(rawInputOf(run.permissions[1]!)).toContain('"runner":"remote"');
        expect(execEvents(fixture).length).toBeGreaterThan(0);
        // Both runs printed the command's output, so the remote run got past its own request.
        expect((toolTexts(fixture.gateway).match(/same-command/g) ?? []).length).toBeGreaterThanOrEqual(2);
      },
    );
  }, TIMEOUT * 3);
});

describe("an isolated folder with nothing set up, and a missing login (A1, E5)", () => {
  test("an isolated folder with nothing set up asks the setup question, then runs isolated", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo isolated-one" }),
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.map((e) => e.message)).toEqual([p2Message(fakeTeam.slug)]);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain("isolated-one");
          expect(texts).toContain(`fx: ran isolated on vercel:${fakeTeam.slug}/${fakeTeam.projects[0]!.name}`);
          expectNoSetupNames(fixture.gateway);
        },
        () => ({ remote: undefined, rules: [{ command: "echo isolated-one", runner: "isolated" }] }),
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("E5: a user who is logged out after setup is told to log in, and no refusal reaches the model without its reason", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo logged-out", runner: "remote" }),
        async (fixture) => {
          const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
            cwd: fixture.workspace,
            timeoutMs: TIMEOUT,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), VERCEL_TOKEN: undefined },
          });
          expect(result.code).toBe(0);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain(E5_NO_LOGIN);
          expect(texts).not.toContain("cannot be used: ");
          expect(execEvents(fixture)).toEqual([]);
        },
        undefined,
        true,
        setup,
      );
    });
  }, TIMEOUT);
});

// The sizes of a real account (U5, U6): thirty teams, and a team whose 25 projects put
// `fx-sandbox` past the first page of 20. Entries are padded to the real entry sizes.
describe("remote setup with the sizes of a real account (U5, U6)", () => {
  const bigTeam: SetupTeam = {
    ...fakeTeam,
    projects: [
      ...Array.from({ length: 24 }, (_, index): SetupProject => ({ id: `prj_big_${index}`, name: `project-${index}` })),
      { id: "prj_sandbox", name: "fx-sandbox" },
    ],
  };
  const otherTeams: SetupTeam[] = Array.from({ length: 29 }, (_, index) => ({
    id: `team_big_${index}`,
    slug: `big-${index}`,
    name: `Big ${index}`,
    projects: [],
  }));

  test("setup lists the teams and projects, offers fx-sandbox as existing, and the run goes on", async () => {
    await withSetup({ teams: [bigTeam, ...otherTeams], padding: { team: 40 * 1024, project: 200 * 1024 } }, async (setup) => {
      await withSandboxFixture(
        [fakeGatewayToolCall("call-1", "shell", { command: "echo sized", runner: "remote" }), fakeGatewayFinalText("done\n")],
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(bigTeam.id, "prj_sandbox"));
          const texts = toolTexts(fixture.gateway);
          expect(texts).not.toContain("too large");
          expect(run.elicitations.map((e) => e.message)).toEqual([P1_MESSAGE, p2Message(bigTeam.slug)]);
          expectRemoteWritten(fixture, bigTeam, { id: "prj_sandbox", name: "fx-sandbox" }, fakeUser.id);
          expect(texts).toContain("sized");
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);
});

describe("remote setup over ACP: the prompts and the first run (AC-5, AC-6)", () => {
  test("AC-5: two teams: a team prompt, then a project prompt, one write, the command runs remote, and a second remote call asks nothing", async () => {
    await withSetup({ teams: [fakeTeam, fakeSecondTeam] }, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "echo first", runner: "remote" }),
          fakeGatewayToolCall("call-2", "shell", { command: "echo second", runner: "remote" }),
          fakeGatewayFinalText("done\n"),
        ],
        async (fixture) => {
          const run = await acpRun(fixture, ["Run two commands."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.map((e) => e.message)).toEqual([P1_MESSAGE, p2Message(fakeTeam.slug)]);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain("first");
          expect(texts).toContain("second");
          expect(execEvents(fixture).length).toBeGreaterThan(0);
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
          expectNoSetupNames(fixture.gateway);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("ACP, one team: one project prompt with the exact message, one write, and the command runs remote", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo one", runner: "remote" }),
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.map((e) => e.message)).toEqual([p2Message(fakeTeam.slug)]);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          expect(sandboxConfigText(fixture).split('"remote"').length - 1).toBe(1);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain("one");
          expect(execEvents(fixture).length).toBeGreaterThan(0);
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("AC-6: the client declines the project prompt, so both calls are E8 in the turn, with one prompt and the config unchanged", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "echo one", runner: "remote" }),
          fakeGatewayToolCall("call-2", "shell", { command: "echo two", runner: "remote" }),
          fakeGatewayFinalText("done\n"),
        ],
        async (fixture) => {
          const before = sandboxConfigText(fixture);
          const run = await acpRun(fixture, ["Run two commands."], () => ({ action: "decline" }));
          expect(run.elicitations.length).toBe(1);
          const texts = toolTexts(fixture.gateway);
          expect(callsWithResult(fixture.gateway, E8_DECLINED)).toBe(2);
          expect(sandboxConfigText(fixture)).toBe(before);
          expect(execEvents(fixture)).toEqual([]);
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("a decline on the team prompt is E8 for the rest of the turn with no prompt, and a new prompt asks again", async () => {
    await withSetup({ teams: [fakeTeam, fakeSecondTeam] }, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "echo one", runner: "remote" }),
          fakeGatewayToolCall("call-2", "shell", { command: "echo two", runner: "remote" }),
          fakeGatewayFinalText("first turn done\n"),
          fakeGatewayToolCall("call-3", "shell", { command: "echo three", runner: "remote" }),
          fakeGatewayFinalText("second turn done\n"),
        ],
        async (fixture) => {
          let teamPrompts = 0;
          const run = await acpRun(fixture, ["First turn.", "Second turn."], (params) => {
            if ("team" in (params.requestedSchema?.properties ?? {})) {
              teamPrompts += 1;
              return teamPrompts === 1
                ? { action: "decline" }
                : { action: "accept", content: { team: fakeTeam.id } };
            }
            return { action: "accept", content: { project: fakeTeam.projects[0]!.id } };
          });
          expect(run.elicitations.map((e) => [e.turn, e.message])).toEqual([
            [1, P1_MESSAGE],
            [2, P1_MESSAGE],
            [2, p2Message(fakeTeam.slug)],
          ]);
          const texts = toolTexts(fixture.gateway);
          expect(callsWithResult(fixture.gateway, E8_DECLINED)).toBe(2);
          expect(texts).toContain("three");
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 4);

  test("a team name with an escape sequence shows with no ESC byte in the ACP prompt, and the step gets the team's id", async () => {
    const escaped: SetupTeam = {
      id: "team_fx_esc",
      slug: "evil-team",
      name: "evil\x1b[2Jteam",
      projects: [{ id: "prj_fx_esc", name: "esc-project" }],
    };
    await withSetup({ teams: [escaped, fakeSecondTeam] }, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo esc", runner: "remote" }),
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(escaped.id, escaped.projects[0]!.id));
          const titles = (run.elicitations[0]!.params.requestedSchema.properties.team.oneOf as Array<{ title: string }>).map(
            (option) => option.title,
          );
          expect(titles.some((title) => title.includes("evil"))).toBe(true);
          for (const title of titles) expect(title).not.toContain("\x1b");
          expect(JSON.stringify(run.elicitations)).not.toContain("\\u001b");
          expectRemoteWritten(fixture, escaped, escaped.projects[0]!, fakeUser.id);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("AC-20: a config file that cannot be read is refused on the write, and its bytes are unchanged", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo cfg", runner: "remote" }),
        async (fixture) => {
          const broken = '{"provider_args": [';
          writeFileSync(join(fixture.home, ".fx", "sandbox", "config.json"), broken);
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(sandboxConfigText(fixture)).toBe(broken);
          expect(execEvents(fixture)).toEqual([]);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain("fx did not run this command: ");
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("AC-18: a token for another user: the config's remote names the other user, so the project prompt appears again", async () => {
    await withSetup({ user: fakeOtherUser }, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo again", runner: "remote" }),
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.map((e) => e.message)).toEqual([p2Message(fakeTeam.slug)]);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeOtherUser.id);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain("again");
          expectNoInterimText(texts, JSON.stringify(run.elicitations));
        },
        (repo) => ({ remote: setup.remoteFor(fakeTeam, fakeTeam.projects[0]!, fakeUser.id) }),
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);
});

describe("remote setup without a channel, and the login refusals (AC-7, AC-18, AC-30, E10)", () => {
  test("AC-7: fx ask --json with no remote and no channel gives E7 within 5 s, asks nothing, and writes no config", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo headless", runner: "remote" }),
        async (fixture) => {
          const before = sandboxConfigText(fixture);
          const started = Date.now();
          const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
            cwd: fixture.workspace,
            timeoutMs: TIMEOUT,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), ...setup.env },
          });
          const elapsed = Date.now() - started;
          expect(result.code).toBe(0);
          expect(elapsed).toBeLessThan(5000);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain(E7_NO_CHANNEL);
          expect(sandboxConfigText(fixture)).toBe(before);
          expect(execEvents(fixture)).toEqual([]);
          expect(setup.api.log).toEqual([]);
          expectNoInterimText(texts);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT);

  test("AC-18: no token and no auth file gives E5, with no request to the fake", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo none", runner: "remote" }),
        async (fixture) => {
          const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
            cwd: fixture.workspace,
            timeoutMs: TIMEOUT,
            env: {
              ...gatewayEnv(fixture.home, fixture.gateway),
              FX_TEST_VERCEL_API_URL: setup.api.url,
              XDG_DATA_HOME: undefined,
            },
          });
          expect(result.code).toBe(0);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain(E5_NO_LOGIN);
          expect(setup.api.log).toEqual([]);
          expect(execEvents(fixture)).toEqual([]);
          expectNoInterimText(texts);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT);

  test("AC-18: an expired auth.json gives E6, with no request to the fake", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo expired", runner: "remote" }),
        async (fixture) => {
          for (const dir of [
            join(fixture.home, ".local", "share", "com.vercel.cli"),
            join(fixture.home, "Library", "Application Support", "com.vercel.cli"),
          ]) {
            mkdirSync(dir, { recursive: true });
            writeFileSync(join(dir, "auth.json"), JSON.stringify({ token: "vca_fx_expired", expiresAt: 1 }));
          }
          const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
            cwd: fixture.workspace,
            timeoutMs: TIMEOUT,
            env: {
              ...gatewayEnv(fixture.home, fixture.gateway),
              FX_TEST_VERCEL_API_URL: setup.api.url,
              XDG_DATA_HOME: undefined,
            },
          });
          expect(result.code).toBe(0);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain(E6_LOGIN_REJECTED);
          expect(setup.api.log).toEqual([]);
          expect(execEvents(fixture)).toEqual([]);
          expectNoInterimText(texts);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT);

  test("AC-30: no token and a non-loopback override gives E5, and the override is not used", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "echo elsewhere", runner: "remote" }),
        async (fixture) => {
          const result = await runFx(["ask", "--json", "--permission-mode", "full-access", "Run it."], {
            cwd: fixture.workspace,
            timeoutMs: TIMEOUT,
            env: {
              ...gatewayEnv(fixture.home, fixture.gateway),
              FX_TEST_VERCEL_API_URL: "http://example.com:9",
            },
          });
          expect(result.code).toBe(0);
          const texts = toolTexts(fixture.gateway);
          expect(texts).toContain(E5_NO_LOGIN);
          expect(setup.api.log).toEqual([]);
          expectNoInterimText(texts);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT);

  test("E10: a sub-agent's remote call with no remote is refused, and the fake sees no request", async () => {
    await withSetup({}, async (setup) => {
      const { home, workspace } = createProfile(true);
      mkdirSync(join(home, ".fx", "sandbox"), { recursive: true });
      writeFileSync(join(home, ".fx", "sandbox", "config.json"), JSON.stringify({ rules: [] }));
      const childBodies: string[] = [];
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes("call-sub")) return fakeGatewayFinalText("delegated\n");
        if (body.includes('"name":"subagent"')) {
          return fakeGatewayToolCall("call-sub", "subagent", {
            action: "message",
            agent: "reviewer",
            message: "Run a remote command.",
            report: "final",
          });
        }
        childBodies.push(body);
        if (body.includes("call-child")) return fakeGatewayFinalText("child done\n");
        return fakeGatewayToolCall("call-child", "shell", { command: "echo child", runner: "remote" });
      });
      gateways.push(gateway);
      const result = await runFx(["ask", "--json", "--yolo", "Delegate a remote command."], {
        cwd: workspace,
        timeoutMs: TIMEOUT * 2,
        env: { ...gatewayEnv(home, gateway), ...setup.env },
      });
      expect(result.code).toBe(0);
      expect(childBodies.some((body) => body.includes(E10_SUB_AGENT))).toBe(true);
      expect(setup.api.log).toEqual([]);
    });
  }, TIMEOUT * 2);
});

describe("a sub-agent's remote call over ACP, which has a channel (U2, E10)", () => {
  test("E10 in ACP: the sub-agent's remote call gets E10, asks nothing, and the fake sees no request", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        (body) => {
          if (body.includes("call-sub")) return fakeGatewayFinalText("delegated\n");
          if (body.includes('"name":"subagent"')) {
            return fakeGatewayToolCall("call-sub", "subagent", {
              action: "message",
              agent: "reviewer",
              message: "Run a remote command.",
              report: "final",
            });
          }
          if (body.includes("call-child")) return fakeGatewayFinalText("child done\n");
          return fakeGatewayToolCall("call-child", "shell", { command: "echo child", runner: "remote" });
        },
        async (fixture) => {
          const run = await acpRun(fixture, ["Delegate a remote command."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations).toEqual([]);
          expect(toolTexts(fixture.gateway)).toContain(E10_SUB_AGENT);
          expect(setup.api.log).toEqual([]);
          expectNoInterimText(toolTexts(fixture.gateway));
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);
});

describe("login changes, first use, the model's view and include (V1, R5, AC-5, AC-34)", () => {
  test("a login that changes to another user after a run: the next call starts setup again, and never runs on the other account", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "echo first-account", runner: "remote" }),
          fakeGatewayFinalText("one\n"),
          fakeGatewayToolCall("call-2", "shell", { command: "echo second-account", runner: "remote" }),
          fakeGatewayFinalText("two\n"),
        ],
        async (fixture) => {
          const first = await acpRun(fixture, ["Run it."], () => ({ action: "decline" }));
          expect(first.elicitations).toEqual([]);
          expect(setup.api.log.filter((entry) => entry.route === "cmd" && entry.kind === "exec")).toHaveLength(1);

          // The login is now another account's: a new token, which the fake signs in as that user.
          fixture.setup.env.VERCEL_TOKEN = "fx-test-login-other";
          setup.api.signInAs(fakeApiToken, fakeOtherUser);
          const mark = setup.api.log.length;
          const second = await acpRun(fixture, ["Run again."], () => ({ action: "decline" }));
          expect(second.elicitations.length).toBeGreaterThan(0);
          const after = setup.api.log.slice(mark);
          expect(after.some((entry) => entry.route === "user" && entry.status === 200)).toBe(true);
          expect(after.filter((entry) => entry.route === "cmd" || entry.route === "write")).toEqual([]);
          expect(sandboxConfigText(fixture)).toContain(fakeUser.id);
          expect(JSON.stringify(setup.api.log)).not.toContain("fx-test-login-other");
        },
        undefined,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("a fresh profile with no sandbox folder: the first remote setup writes the config, and the command runs", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [fakeGatewayToolCall("call-1", "shell", { command: "echo fresh-profile", runner: "remote" }), fakeGatewayFinalText("done\n")],
        async (fixture) => {
          rmSync(join(fixture.home, ".fx", "sandbox"), { recursive: true, force: true });
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.map((e) => e.message)).toEqual([p2Message(fakeTeam.slug)]);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          expect(toolResults(fixture.gateway).some((text) => text.includes("fresh-profile"))).toBe(true);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test("AC-5: no fake-gateway request body carries a setup list's team or project id or name", async () => {
    await withSetup({ teams: [fakeTeam, fakeSecondTeam] }, async (setup) => {
      await withSandboxFixture(
        [fakeGatewayToolCall("call-1", "shell", { command: "echo listed", runner: "remote" }), fakeGatewayFinalText("done\n")],
        async (fixture) => {
          const run = await acpRun(fixture, ["Run it."], answerSetup(fakeTeam.id, fakeTeam.projects[0]!.id));
          expect(run.elicitations.length).toBeGreaterThan(0);
          // The run's own destination is named in its N14 line (the model may see it, R270), so only the lists are checked.
          const listed = [fakeSecondTeam.id, fakeSecondTeam.slug, fakeSecondTeam.name, fakeSecondTeam.projects[0]!.id, fakeSecondTeam.projects[0]!.name, fakeTeam.id, fakeTeam.name, fakeTeam.projects[0]!.id];
          expect(fixture.gateway.requests.length).toBeGreaterThan(0);
          for (const request of fixture.gateway.requests) {
            for (const text of listed) expect(request.body).not.toContain(text);
          }
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 2);

  test("AC-34: include sends .env with a remote run, and a missing include is named (N17)", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "if [ -e .env ]; then echo has-env; else echo no-env; fi", runner: "remote" }),
          fakeGatewayFinalText("done\n"),
        ],
        async (fixture) => {
          writeFileSync(join(fixture.workspace, ".gitignore"), ".env\n");
          writeFileSync(join(fixture.workspace, ".env"), "SECRET=1\n");
          await askSandbox(fixture);
          const results = toolResults(fixture.gateway);
          expect(results[0]).toContain("has-env");
          // N17 (spec row 427): the missing include path is named once, in the remote run's result.
          expect(results[0]).toContain("fx: include path missing.txt was not found");
        },
        (repo) => ({ include: { [repo]: [".env", "missing.txt"] } }),
        true,
        setup,
      );
    });
  }, TIMEOUT * 2);

  // The fake keeps one file tree for every sandbox, so this runs alone: a run before it would leave its .env behind.
  test("AC-34: an isolated run leaves include out, so a .env the include names is not sent", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "iso-check; if [ -e .env ]; then echo has-env; else echo no-env; fi" }),
          fakeGatewayFinalText("done\n"),
        ],
        async (fixture) => {
          writeFileSync(join(fixture.workspace, ".gitignore"), ".env\n");
          writeFileSync(join(fixture.workspace, ".env"), "SECRET=1\n");
          await askSandbox(fixture);
          const results = toolResults(fixture.gateway);
          expect(results[0]).toContain("no-env");
          expect(results[0]).not.toContain("missing.txt");
        },
        (repo) => ({ include: { [repo]: [".env", "missing.txt"] }, rules: [{ command: "iso-*", runner: "isolated" }] }),
        true,
        setup,
      );
    });
  }, TIMEOUT * 2);

  test.skipIf(!tmuxAvailable())("fx ask in a terminal with a fresh profile: the first setup writes the config, and the command runs", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "printf 'fresh-tmux\\n'", runner: "remote" }),
        async (fixture) => {
          rmSync(join(fixture.home, ".fx", "sandbox"), { recursive: true, force: true });
          const session = await TmuxSession.create({
            cmd: `${FX_BIN} ask --permission-mode full-access "Run it."`,
            cwd: fixture.workspace,
            width: 200,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), ...setup.env },
          });
          sessions.push(session);
          expect(await session.waitForText("fx asks", TIMEOUT)).toContain("fx asks");
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          await session.waitForText("Another project (optional)", TIMEOUT);
          await session.sendLiteral("2");
          await session.sendKeys("Enter");
          await session.waitForText("Submit, Edit, Decline, or Cancel", TIMEOUT);
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          expect(toolResults(fixture.gateway).some((text) => text.includes("fresh-tmux"))).toBe(true);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test.skipIf(!tmuxAvailable())("the TUI with a fresh profile: the first remote call sets up, and the second runs with no question", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("tui-call-1", "shell", { command: "printf 'tui-1\\n'", runner: "remote" }),
          fakeGatewayFinalText("First done.\n"),
          fakeGatewayToolCall("tui-call-2", "shell", { command: "printf 'tui-2\\n'", runner: "remote" }),
          fakeGatewayFinalText("Second done.\n"),
        ],
        async (fixture) => {
          rmSync(join(fixture.home, ".fx", "sandbox"), { recursive: true, force: true });
          const session = await TmuxSession.create({
            cmd: FX_BIN,
            cwd: fixture.workspace,
            width: 200,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), ...setup.env, FX_PERMISSION_MODE: "full-access" },
          });
          sessions.push(session);
          await session.waitForComposer(TIMEOUT);
          await session.sendText("Run it.");
          expect(await session.waitForText("fx asks", TIMEOUT)).toContain("fx asks");
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          await session.waitForText("Another project (optional)", TIMEOUT);
          await session.sendKeys("Enter");
          await session.waitForText("Submit, Edit, Decline, or Cancel", TIMEOUT);
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          await session.waitForText("First done.", TIMEOUT);
          await session.waitForStableComposer(TIMEOUT);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          const setupRequests = (): number => setup.api.log.filter((entry) => entry.route === "teams" || entry.route === "write").length;
          const afterFirst = setupRequests();
          await session.sendText("Run again.");
          await session.waitForText("Second done.", TIMEOUT);
          expect(toolResults(fixture.gateway).some((text) => text.includes("tui-2"))).toBe(true);
          expect(setupRequests()).toBe(afterFirst);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);
});

describe("remote setup in a terminal (AC-25)", () => {
  test.skipIf(!tmuxAvailable())("AC-25: fx ask in a terminal shows the fx asks header, and the command runs after the accept", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        shellCall({ command: "printf 'tui%s\\n' ok-42", runner: "remote" }),
        async (fixture) => {
          const session = await TmuxSession.create({
            cmd: `${FX_BIN} ask --permission-mode full-access "Run it."`,
            cwd: fixture.workspace,
            width: 200,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), ...setup.env },
          });
          sessions.push(session);
          const header = await session.waitForText("fx asks", TIMEOUT);
          expect(header).toContain("fx asks");
          // The form lists the projects as numbers: "1. [1] fx-test-project" is the first.
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          // The form then asks the optional "Another project" name. Skip it: option 2.
          await session.waitForText("Another project (optional)", TIMEOUT);
          await session.sendLiteral("2");
          await session.sendKeys("Enter");
          // The completed form is reviewed before it is sent. Submit: option 1.
          await session.waitForText("Submit, Edit, Decline, or Cancel", TIMEOUT);
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          // Known gap, older code (not fixed here): after a prompt, fx ask's live tool group
          // and its final reply write over the prompt's lines (ask_presentation.zig; the prompt
          // writer in cli_ask.zig), so the reply is not reliably on screen. The sandbox log is
          // the evidence until that is fixed. The width is 200: at 120 columns the reason line
          // loses its end, because fx ask turns autowrap off (ask_presentation.zig).
          expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
          expectRemoteWritten(fixture, fakeTeam, fakeTeam.projects[0]!, fakeUser.id);
          // The sandbox started the command and it exited 0.
          const started = events(fixture).find((event) => event.ev === "start" && JSON.stringify(event.argv).includes("ok-42"));
          expect(started).toBeDefined();
          expect(events(fixture).some((event) => event.ev === "exit" && event.id === started!.id && event.code === 0)).toBe(true);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

  test.skipIf(!tmuxAvailable())("fx ask --no-save: a decline holds for the second remote call in the same process (U4)", async () => {
    await withSetup({}, async (setup) => {
      await withSandboxFixture(
        [
          fakeGatewayToolCall("call-1", "shell", { command: "echo one", runner: "remote" }),
          fakeGatewayToolCall("call-2", "shell", { command: "echo two", runner: "remote" }),
          fakeGatewayFinalText("done\n"),
        ],
        async (fixture) => {
          const session = await TmuxSession.create({
            cmd: `${FX_BIN} ask --no-save --permission-mode full-access "Run two commands."`,
            cwd: fixture.workspace,
            env: { ...gatewayEnv(fixture.home, fixture.gateway), ...setup.env },
          });
          sessions.push(session);
          await session.waitForText("fx asks project", TIMEOUT);
          await session.sendLiteral("1");
          await session.sendKeys("Enter");
          await session.waitForText("Another project (optional)", TIMEOUT);
          await session.sendLiteral("2");
          await session.sendKeys("Enter");
          await session.waitForText("Submit, Edit, Decline, or Cancel", TIMEOUT);
          await session.sendLiteral("3");
          await session.sendKeys("Enter");
          // A second form would wait for input, the gateway would get no reply, and this wait would time out.
          expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
          expect(callsWithResult(fixture.gateway, E8_DECLINED)).toBe(2);
          expect(execEvents(fixture)).toEqual([]);
        },
        NO_REMOTE,
        true,
        setup,
      );
    });
  }, TIMEOUT * 3);

});

describe("the built-in runner process: command line, contract and login (block 5a)", () => {
  const REPO_KEY = "0123456789abcdef";
  const runnerLine = (
    digest: string,
    flags: string[] = [],
    mode = "remote",
    repo = "/Users/example/repo",
    state = `/Users/example/.fx/sandbox/state/${REPO_KEY}`,
  ) => [
    "__fx_runner__",
    "run",
    "--contract",
    "1",
    "--mode",
    mode,
    "--root",
    repo,
    "--cwd",
    repo,
    "--state",
    state,
    "--team",
    fakeTeam.id,
    "--project",
    fakeTeam.projects[0]!.id,
    "--token-sha256",
    digest,
    "--team-slug",
    fakeTeam.slug,
    "--project-name",
    fakeTeam.projects[0]!.name,
    "--user-id",
    "usr_fake",
    "--grace-ms",
    "30000",
    ...flags,
    "--",
    "true",
  ];

  function runRunner(env: Record<string, string>, args: string[]) {
    const home = createDir();
    const result = Bun.spawnSync([FX_BIN, ...args], {
      cwd: home,
      env: { PATH: process.env.PATH ?? "", HOME: home, ...env },
      stdout: "pipe",
      stderr: "pipe",
    });
    return { code: result.exitCode, stderr: new TextDecoder().decode(result.stderr) };
  }

  // Async, not spawnSync: the fake API runs in this process, so a blocking spawn would starve it.
  function runRunnerAsync(env: Record<string, string>, args: string[]): Promise<{ code: number | null; stderr: string }> {
    const home = createDir();
    return new Promise((resolve, reject) => {
      const child = spawn(FX_BIN, args, {
        cwd: home,
        env: { PATH: process.env.PATH ?? "", HOME: home, ...env },
        stdio: ["ignore", "pipe", "pipe"],
      });
      children.push(child);
      let stderr = "";
      child.stderr?.setEncoding("utf8");
      child.stderr?.on("data", (chunk: string) => (stderr += chunk));
      child.on("error", reject);
      child.on("close", (code) => resolve({ code, stderr }));
    });
  }

  const digestOf = (text: string) => new Bun.CryptoHasher("sha256").update(text).digest("hex");

  test("a wrong --token-sha256 refuses with N10, exits 125, and sends no request (V1)", async () => {
    await withSetup({}, async (setup) => {
      const result = runRunner(setup.env, runnerLine(digestOf("not-the-login")));
      expect(result.code).toBe(125);
      expect(result.stderr).toBe("fx: did not run: the Vercel login changed during the call\n");
      expect(setup.api.log).toEqual([]);
    });
  });

  test("the right --token-sha256 passes the login check: the first API request reaches the fake with the test token (V1)", async () => {
    const repo = createDir();
    const stateParent = join(createDir(), "sandbox", "state");
    mkdirSync(stateParent, { recursive: true });
    await withSetup({ macRoots: [repo] }, async (setup) => {
      const result = await runRunnerAsync(
        setup.env,
        runnerLine(digestOf(setup.env.VERCEL_TOKEN!), [], "remote", repo, join(stateParent, REPO_KEY)),
      );
      expect(result.stderr).not.toContain("the Vercel login changed");
      expect(result.stderr).not.toContain("no Vercel login");
      expect(setup.api.log.length).toBeGreaterThan(0);
      expect(setup.api.log[0]!.status).toBe(200);
      expect(setup.api.log.filter((entry) => entry.status === 401 || entry.status === 403)).toEqual([]);
      expect(JSON.stringify(setup.api.log)).not.toContain(fakeLoginToken);
      expect(result.code).toBe(0);
    });
  }, TIMEOUT * 2);

  test("an old host's --contract gets N12 whatever else its line says (L4, AC-26)", async () => {
    await withSetup({}, async (setup) => {
      const result = runRunner(setup.env, [
        "__fx_runner__", "run", "--contract", "2", "--mode", "remote", "--frozen-flag", "x", "--", "true",
      ]);
      expect(result.code).toBe(125);
      expect(result.stderr).toBe("fx: did not run: fx was updated while this session ran. Run the command again.\n");
      expect(setup.api.log).toEqual([]);
    });
  });

  test("a line without --team refuses by name, exits 125, and sends no request (L1)", async () => {
    await withSetup({}, async (setup) => {
      const full = runnerLine(digestOf(setup.env.VERCEL_TOKEN!));
      const withoutTeam = full.filter((_, index) => index !== full.indexOf("--team") && index !== full.indexOf("--team") + 1);
      const result = runRunner(setup.env, withoutTeam);
      expect(result.code).toBe(125);
      expect(result.stderr).toBe("fx: did not run: the runner arguments are wrong: --team is missing\n");
      expect(setup.api.log).toEqual([]);
    });
  });
});

describe("with the runner field on, a run that names runner is refused before anything runs (AC-32)", () => {
  test("E13: runner remote with a cwd outside the workspace", async () => {
    const outside = createDir();
    await withSandboxFixture(shellCall({ action: "run", command: "true", runner: "remote", cwd: outside }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(
        `${REFUSAL_PREFIX}a remote run needs a cwd inside the workspace ${fixture.workspace}.`,
      );
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E13 without action: a call with runner remote and no action is inferred as run, then refused", async () => {
    const outside = createDir();
    await withSandboxFixture(shellCall({ command: "true", runner: "remote", cwd: outside }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(
        `${REFUSAL_PREFIX}a remote run needs a cwd inside the workspace ${fixture.workspace}.`,
      );
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E3: runner remote with shell set", async () => {
    await withSandboxFixture(
      shellCall({ action: "run", command: "true", runner: "remote", tty: true, shell: { kind: "executable", path: "/bin/sh" } }),
      async (fixture) => {
        expect(await askSandbox(fixture)).toContain(E3_SHELL);
        expect(execEvents(fixture)).toEqual([]);
      },
    );
  }, TIMEOUT * 2);

  test("E3: runner remote with reload true", async () => {
    await withSandboxFixture(shellCall({ action: "run", command: "true", runner: "remote", reload: true }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(E3_RELOAD);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E3: runner remote with profile user", async () => {
    await withSandboxFixture(shellCall({ action: "run", command: "true", runner: "remote", profile: "user" }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(E3_PROFILE);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E12 is unchanged: runner remote with tty and no other local-only field", async () => {
    await withSandboxFixture(shellCall({ action: "run", command: "true", runner: "remote", tty: true }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(E12);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E1: runner gpu", async () => {
    await withSandboxFixture(shellCall({ action: "run", command: "true", runner: "gpu" }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(E1);
      expect(execEvents(fixture)).toEqual([]);
    });
  }, TIMEOUT * 2);

  test("E2: runner on stop", async () => {
    await withSandboxFixture(shellCall({ action: "stop", session_id: "s1", runner: "remote" }), async (fixture) => {
      expect(await askSandbox(fixture)).toContain(E2_STOP);
      expect(execEvents(fixture)).toEqual([]);
      // A refused call reaches no request at all.
      expect(fixture.setup.api.log).toEqual([]);
    });
  }, TIMEOUT * 2);
});

// The built-in remote runner as a process (spec V5, V6): the real `fx __fx_runner__`
// pushes a repository and runs one command in the fake sandbox. The fake runs the wrapper
// and the command with bash under its private root, and maps the runner's Mac paths there.
// The fake needs a Linux host: it runs the sandbox's scripts with this host's tools (GNU find, stat and head).
type RunnerResult = { code: number | null; stdout: string; stderr: string };

describe("the built-in remote runner runs a command through the fake sandbox", () => {
  let runRoot: string;
  let runner: RemoteSetupFixture;
  beforeAll(() => {
    // macOS keeps $TMPDIR under the /var symlink, and the runner refuses a state path with a symlink in it.
    runRoot = realpathSync(mkdtempSync(join(tmpdir(), "fx-runner-e2e-")));
    runner = startRemoteSetupFixture({ macRoots: [runRoot] });
  });
  afterAll(() => {
    runner?.stop();
    rmSync(runRoot, { recursive: true, force: true });
  });

  function makeRepo(key: string): string {
    const repo = join(runRoot, "repos", key);
    mkdirSync(repo, { recursive: true });
    return repo;
  }

  // The repo key is sixteen lowercase hex digits (L5), so each repo gets a name of that shape.
  const keyOf = (repo: string) => createHash("sha256").update(basename(repo)).digest("hex").slice(0, 16);
  const homeOf = (repo: string) => join(runRoot, "homes", basename(repo));
  const stateOf = (repo: string) => join(homeOf(repo), "sandbox", "state", keyOf(repo));

  // Removes a repository, its copy in the fake sandbox, and its home on this Mac. The tests that write thousands of
  // files call it in `finally`, under their own timeout: left to the describe's afterAll, those trees took 9.5 s
  // on a loaded host, past Bun's 5 s hook timeout.
  function discardRepo(repo: string): void {
    rmSync(runner.api.remotePath(repo), { recursive: true, force: true });
    rmSync(homeOf(repo), { recursive: true, force: true });
    rmSync(repo, { recursive: true, force: true });
  }

  function spawnRemote(
    repo: string,
    command: string,
    include: string[] = [],
    bringBack: string[] = [],
    extra: string[] = [],
    mode: "remote" | "isolated" = "remote",
  ): { child: ChildProcess; result: Promise<RunnerResult> } {
    const home = homeOf(repo);
    const state = stateOf(repo);
    mkdirSync(join(home, "sandbox", "state"), { recursive: true });
    const digest = createHash("sha256").update(fakeLoginToken).digest("hex");
    const args = [
      "__fx_runner__",
      "run",
      "--contract",
      "1",
      "--mode",
      mode,
      "--root",
      repo,
      "--cwd",
      repo,
      "--state",
      state,
      "--team",
      fakeTeam.id,
      "--project",
      fakeTeam.projects[0]!.id,
      "--token-sha256",
      digest,
      "--team-slug",
      fakeTeam.slug,
      "--project-name",
      fakeTeam.projects[0]!.name,
      "--user-id",
      "usr_fake",
      "--grace-ms",
      "30000",
      ...include.flatMap((path) => ["--include", path]),
      ...bringBack.flatMap((path) => ["--bring-back", path]),
      ...extra,
      "--",
      command,
    ];
    const env = { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, ...runner.env };
    const child = spawn(FX_BIN, args, { cwd: repo, env, stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    const result = new Promise<RunnerResult>((resolve, reject) => {
      let stdout = "";
      let stderr = "";
      child.stdout?.setEncoding("utf8");
      child.stderr?.setEncoding("utf8");
      child.stdout?.on("data", (chunk: string) => (stdout += chunk));
      child.stderr?.on("data", (chunk: string) => (stderr += chunk));
      child.on("error", reject);
      child.on("close", (code) => resolve({ code, stdout, stderr }));
    });
    return { child, result };
  }

  function runRemote(repo: string, command: string): Promise<RunnerResult> {
    return spawnRemote(repo, command).result;
  }

  // The session of the repo's sandbox ends between two runs, as when Vercel stops it (V3).
  async function stopSandboxSession(repo: string): Promise<void> {
    const sandbox = runner.api.sandboxes().find((item) => item.name === `fx-${keyOf(repo)}`);
    expect(sandbox).toBeDefined();
    const answer = await fetch(`${runner.api.url}/v2/sandboxes/sessions/${sandbox!.session}/stop?teamId=${fakeTeam.id}`, {
      method: "POST",
      headers: { authorization: `Bearer ${fakeApiToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(answer.status).toBe(200);
  }

  // The status of each command request whose text names `text`, in the order the runner sent them.
  const commandStatuses = (entries: FakeVercelLogEntry[], text: string) =>
    entries
      .filter((entry) => entry.route === "cmd" && JSON.stringify(entry.body ?? "").includes(text))
      .map((entry) => entry.status);

  // The N14 line after a bring-back that finished, with `n` files back (V9).
  const ranLine = (n: number) =>
    `fx: ran on remote vercel:${fakeTeam.slug}/${fakeTeam.projects[0]!.name}; ${n} ${n === 1 ? "file" : "files"} back\n`;

  // The N14 line of an isolated run names its runs folder, which has a new id for each run.
  const expectIsolatedRan = (stderr: string, n: number) =>
    expect(stderr).toMatch(
      new RegExp(
        `^fx: ran isolated on vercel:${fakeTeam.slug}/${fakeTeam.projects[0]!.name}; ${n} ${n === 1 ? "file" : "files"} saved in .+/runs/[0-9a-f]+\\n$`,
      ),
    );

  // Waits until the condition holds, polling the fake's state, and fails after the test timeout.
  async function waitFor(condition: () => boolean): Promise<void> {
    const deadline = Date.now() + TIMEOUT;
    while (!condition()) {
      if (Date.now() > deadline) throw new Error("the condition was not reached in time");
      await new Promise((done) => setTimeout(done, 20));
    }
  }

  const execsSince = (before: number) =>
    runner.api.log.slice(before).filter((entry) => entry.route === "cmd" && entry.kind === "exec").length;

  test("AC-3: stdout, stderr and exit 7, one N14 line, the write, exec and bring-back in order, and made.txt only after the bring-back request", async () => {
    const repo = makeRepo("ac-3");
    writeFileSync(join(repo, "a.txt"), "hello\n");
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo hi; echo err >&2; touch made.txt; exit 7");
    expect(result.stdout).toBe("hi\n");
    expect(result.stderr).toBe(`err\n${ranLine(1)}`);
    expect(result.code).toBe(7);
    const log = runner.api.log.slice(before);
    const write = log.find((entry) => entry.route === "write");
    const exec = log.find((entry) => entry.route === "cmd" && entry.kind === "exec");
    const back = log.find((entry) => entry.route === "cmd" && entry.kind === "bring_back");
    expect(write).toBeDefined();
    expect(exec).toBeDefined();
    expect(back).toBeDefined();
    expect(write!.seq).toBeLessThan(exec!.seq);
    expect(exec!.seq).toBeLessThan(back!.seq);
    expect(exec!.body).toMatchObject({ wait: true, logs: true });
    // A write sets the change time, which a restored modification time cannot change. The file's change
    // time is therefore at or after the bring-back request began.
    expect(statSync(join(repo, "made.txt")).ctimeMs).toBeGreaterThanOrEqual(runner.api.startedAt + back!.at);
  }, TIMEOUT * 2);

  test("AC-30: every request to the fake carries the test token, and none carries the login", async () => {
    const before = runner.api.log.length;
    const result = await runRemote(makeRepo("auth-class"), "true");
    expect(result.code).toBe(0);
    const entries = runner.api.log.slice(before);
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.map((entry) => entry.auth)).toEqual(entries.map(() => "test"));
  }, TIMEOUT * 2);

  test("echo hi prints hi on stdout, and the runner exits 0 (V6)", async () => {
    const result = await runRemote(makeRepo("echo-hi"), "echo hi");
    expect(result.stdout).toBe("hi\n");
    expect(result.stderr).toBe(ranLine(0));
    expect(result.code).toBe(0);
  }, TIMEOUT * 2);

  test("exit 7 makes the runner exit 7 (V6)", async () => {
    const result = await runRemote(makeRepo("exit-seven"), "exit 7");
    expect(result.code).toBe(7);
  }, TIMEOUT * 2);

  test("output on stderr stays on stderr (V6)", async () => {
    const result = await runRemote(makeRepo("stderr"), "echo err >&2");
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe(`err\n${ranLine(0)}`);
    expect(result.code).toBe(0);
  }, TIMEOUT * 2);

  test("a file in the repository arrives in the sandbox with its exact bytes (V5)", async () => {
    const repo = makeRepo("bytes");
    const bytes = Buffer.from([0, 1, 2, 255, 10, 13, 0x41, 0x0a]);
    mkdirSync(join(repo, "dir"), { recursive: true });
    writeFileSync(join(repo, "dir", "data.bin"), bytes);
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    expect(readFileSync(join(runner.api.remotePath(repo), "dir", "data.bin")).equals(bytes)).toBe(true);
  }, TIMEOUT * 2);

  test("a file deleted locally since the last run is removed in the sandbox before the command (V5, V6)", async () => {
    const repo = makeRepo("deleted");
    writeFileSync(join(repo, "gone.txt"), "bye\n");
    expect((await runRemote(repo, "true")).code).toBe(0);
    expect(existsSync(join(runner.api.remotePath(repo), "gone.txt"))).toBe(true);
    rmSync(join(repo, "gone.txt"));
    const result = await runRemote(repo, "test ! -e gone.txt && echo removed");
    expect(result.stdout).toBe("removed\n");
    expect(result.code).toBe(0);
    expect(existsSync(join(runner.api.remotePath(repo), "gone.txt"))).toBe(false);
  }, TIMEOUT * 2);

  test("a file under a 240-byte path arrives intact (V5, GNU long names)", async () => {
    const repo = makeRepo("long-path");
    const dir = "a".repeat(200);
    const name = "b".repeat(39);
    mkdirSync(join(repo, dir), { recursive: true });
    writeFileSync(join(repo, dir, name), "long path\n");
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    expect(readFileSync(join(runner.api.remotePath(repo), dir, name), "utf8")).toBe("long path\n");
  }, TIMEOUT * 2);

  test("a SIGTERM stops a running command: exit 143, N5, and the command is killed (V10, AC-9)", async () => {
    const before = runner.api.log.length;
    const run = spawnRemote(makeRepo("stop-sleep"), "sleep 30");
    await waitFor(() => runner.api.log.slice(before).some((entry) => entry.kind === "exec" && entry.commandId !== undefined));
    run.child.kill("SIGTERM");
    const result = await run.result;
    expect(result.code).toBe(143);
    expect(result.stderr).toBe("fx: stopped; the remote command was killed\n");
    expect(runner.api.commands().some((view) => view.status === "killed" && view.signals.includes(15))).toBe(true);
  }, TIMEOUT * 2);

  test("a connection that drops after the exec body and before the command line is unknown: exit 255 with N3, one exec (V7, AC-10)", async () => {
    runner.api.faults.dropAfterExecBody = "not_run";
    const before = runner.api.log.length;
    const result = await runRemote(makeRepo("drop-before-line"), "true");
    expect(result.code).toBe(255);
    expect(result.stderr).toBe("fx: result unknown: the command may have run; fx did not send it again\n");
    expect(execsSince(before)).toBe(1);
  }, TIMEOUT * 2);

  test("a quiet close reattaches: output a then b once each, exit 0, one exec, one logs and one wait (V8, AC-11)", async () => {
    runner.api.faults.idleCloseAfterBytes = 1;
    const before = runner.api.log.length;
    const result = await runRemote(makeRepo("reattach"), "printf a; sleep 0.4; printf b; exit 0");
    expect(result.stdout).toBe("ab");
    expect(result.stderr).toBe(ranLine(0));
    expect(result.code).toBe(0);
    const routes = runner.api.log.slice(before).map((entry) => entry.route);
    expect(execsSince(before)).toBe(1);
    expect(routes.filter((route) => route === "cmdLogs")).toHaveLength(1);
    expect(routes.filter((route) => route === "cmdGet")).toHaveLength(1);
  }, TIMEOUT * 2);

  test("a session with 25 minutes left is extended before the exec (V12, AC-28)", async () => {
    const repo = makeRepo("extend");
    expect((await runRemote(repo, "true")).code).toBe(0);
    const file = join(stateOf(repo), "sandbox.json");
    const saved = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
    saved.expires_at_ms = Date.now() + 25 * 60 * 1000;
    writeFileSync(file, JSON.stringify(saved));
    const before = runner.api.log.length;
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    const later = runner.api.log.slice(before);
    const extend = later.findIndex((entry) => entry.route === "extendTimeout");
    const exec = later.findIndex((entry) => entry.route === "cmd" && entry.kind === "exec");
    expect(extend).toBeGreaterThanOrEqual(0);
    expect(extend).toBeLessThan(exec);
    expect(later[extend]?.body).toEqual({ duration: 1800000 });
  }, TIMEOUT * 2);

  test("a file the command writes comes back to the repository, and N14 counts it (V9)", async () => {
    const repo = makeRepo("writes-back");
    const result = await runRemote(repo, "echo made > made.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "made.txt"), "utf8")).toBe("made\n");
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 2);

  test("an ignored file the run creates does not come back (V9)", async () => {
    const repo = makeRepo("ignored");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "*.log\n");
    const result = await runRemote(repo, "echo x > build.log");
    expect(result.code).toBe(0);
    expect(existsSync(join(repo, "build.log"))).toBe(false);
    expect(result.stderr).toBe(ranLine(0));
  }, TIMEOUT * 2);

  test("an ignored file that was pushed on purpose comes back (V9)", async () => {
    const repo = makeRepo("ignored-pushed");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "*.log\n");
    writeFileSync(join(repo, "build.log"), "before\n");
    const result = await spawnRemote(repo, "echo changed > build.log", ["build.log"]).result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "build.log"), "utf8")).toBe("changed\n");
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 2);

  test("a file changed on the Mac during the run stays as the Mac has it, and N9 counts it (V9, AC-12)", async () => {
    const repo = makeRepo("keep-mac");
    writeFileSync(join(repo, "a.txt"), "pushed\n");
    const before = runner.api.log.length;
    const run = spawnRemote(repo, "echo sandbox > a.txt; sleep 1");
    await waitFor(() => runner.api.log.slice(before).some((entry) => entry.kind === "exec"));
    writeFileSync(join(repo, "a.txt"), "mac\n");
    const result = await run.result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "a.txt"), "utf8")).toBe("mac\n");
    expect(result.stderr).toBe(`fx: kept your version of 1 file changed on this machine during the run\n${ranLine(0)}`);
  }, TIMEOUT * 2);

  test("hostile archive entries are refused, and nothing outside the repository changes (V9, AC-14)", async () => {
    const repo = makeRepo("hostile");
    const outside = join(runRoot, "outside");
    mkdirSync(outside, { recursive: true });
    symlinkSync(outside, join(repo, "sub"));
    runner.api.faults.hostileBringBack = true;
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    expect(result.stderr).toBe(
      [
        "fx: 1 file not brought back: not regular files",
        "fx: 2 files not brought back: outside the repository",
        "fx: 4 files not brought back: inside .git",
        "fx: 1 file not brought back: a folder on this machine is a link or a file",
        ranLine(0).trimEnd(),
      ].map((line) => `${line}\n`).join(""),
    );
    expect(existsSync(join(outside, "y"))).toBe(false);
    expect(existsSync(join(outside, ".git"))).toBe(false);
    expect(existsSync(join(runRoot, "repos", "x"))).toBe(false);
    expect(existsSync("/abs")).toBe(false);
    expect(existsSync(join(repo, ".git", "hooks", "pre-commit"))).toBe(false);
    expect(existsSync(join(repo, ".g\u200cit", "config"))).toBe(false);
  }, TIMEOUT * 2);

  test("past 2,000 files, the rest stay pending and the next run brings them back (V9)", async () => {
    const repo = makeRepo("cap");
    try {
      const result = await runRemote(repo, "i=1; while [ $i -le 2005 ]; do echo $i > f$i.txt; i=$((i+1)); done");
      expect(result.code).toBe(0);
      expect(result.stderr).toBe(
        `fx: 5 files not brought back: past this run's limit of 2,000 files or 64 MiB; the next run brings them back\n${ranLine(2000)}`,
      );
      const next = await runRemote(repo, "true");
      expect(next.stderr).toBe(ranLine(5));
      expect(readFileSync(join(repo, "f2005.txt"), "utf8")).toBe("2005\n");
    } finally {
      discardRepo(repo);
    }
  }, TIMEOUT * 4);

  test("AC-22: 2,001 new files: 2,000 come back, and N8 counts the one left for the next run (V9)", async () => {
    const repo = makeRepo("ac-22");
    try {
      const result = await runRemote(repo, "i=1; while [ $i -le 2001 ]; do echo $i > f$i.txt; i=$((i+1)); done");
      expect(result.code).toBe(0);
      expect(result.stderr).toBe(
        `fx: 1 file not brought back: past this run's limit of 2,000 files or 64 MiB; the next run brings them back\n${ranLine(2000)}`,
      );
      expect(readdirSync(repo).filter((name) => /^f\d+\.txt$/.test(name))).toHaveLength(2000);
    } finally {
      discardRepo(repo);
    }
  }, TIMEOUT * 4);

  test("an include walk past its entry limit prints N20 once, and the run still goes on (V5, N20)", async () => {
    const repo = makeRepo("cut-walk");
    try {
      mkdirSync(join(repo, "conf"));
      for (let i = 0; i < 10_001; i++) writeFileSync(join(repo, "conf", `f${i}.txt`), "x");
      const result = await spawnRemote(repo, "true", ["conf"]).result;
      expect(result.code).toBe(0);
      const note = "fx: the file list was cut short, so nothing was deleted in the sandbox\n";
      expect(result.stderr.split(note).length - 1).toBe(1);
    } finally {
      discardRepo(repo);
    }
  }, TIMEOUT * 4);

  test("an ignored file under a bring-back root comes back to the Mac (V9)", async () => {
    const repo = makeRepo("root-ignored");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const result = await spawnRemote(repo, "mkdir -p zig-out/bin && echo app > zig-out/bin/app", [], ["zig-out/bin"]).result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "app"), "utf8")).toBe("app\n");
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 2);

  test("a bring-back file the Mac changed during the run stays as the Mac has it, and N9 counts it (V9)", async () => {
    const repo = makeRepo("root-kept");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    mkdirSync(join(repo, "zig-out", "bin"), { recursive: true });
    writeFileSync(join(repo, "zig-out", "bin", "app"), "before\n");
    const before = runner.api.log.length;
    const run = spawnRemote(repo, "mkdir -p zig-out/bin && echo sandbox > zig-out/bin/app && sleep 1", [], ["zig-out/bin"]);
    await waitFor(() => runner.api.log.slice(before).some((entry) => entry.kind === "exec"));
    writeFileSync(join(repo, "zig-out", "bin", "app"), "mac edit and longer\n");
    const result = await run.result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "app"), "utf8")).toBe("mac edit and longer\n");
    expect(result.stderr).toBe(`fx: kept your version of 1 file changed on this machine during the run\n${ranLine(0)}`);
  }, TIMEOUT * 2);

  test("a stopped run's files come back at the next run, and its bring-back outputs do not (V9)", async () => {
    const repo = makeRepo("stopped-then-next");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const run = spawnRemote(repo, "echo x > stopped.txt && mkdir -p zig-out/bin && echo y > zig-out/bin/app && sleep 30", [], ["zig-out/bin"]);
    const app = join(runner.api.remotePath(repo), "zig-out", "bin", "app");
    await waitFor(() => existsSync(app));
    run.child.kill("SIGTERM");
    const stopped = await run.result;
    expect(stopped.code).toBe(143);
    expect(readdirSync(join(stateOf(repo), "pending"))).toHaveLength(1);

    const next = await runRemote(repo, "true");
    expect(next.code).toBe(0);
    expect(readFileSync(join(repo, "stopped.txt"), "utf8")).toBe("x\n");
    expect(existsSync(join(repo, "zig-out", "bin", "app"))).toBe(false);
    expect(readdirSync(join(stateOf(repo), "pending"))).toEqual([]);
    expect(next.stderr).toBe(ranLine(1));
  }, TIMEOUT * 4);

  test("a bring-back cut on the Mac side keeps its stamps, so the next run brings the file back (V9)", async () => {
    const repo = makeRepo("bring-back-cut");
    expect((await runRemote(repo, "true")).code).toBe(0);
    runner.api.faults.cutBringBackAfterBytes = 1;
    const cut = await runRemote(repo, "echo made > made.txt");
    expect(cut.code).toBe(0);
    expect(cut.stderr).toContain("fx: did not bring back the files:");
    expect(existsSync(join(repo, "made.txt"))).toBe(false);
    expect(readdirSync(join(stateOf(repo), "pending"))).toHaveLength(1);

    const next = await runRemote(repo, "true");
    expect(next.code).toBe(0);
    expect(readFileSync(join(repo, "made.txt"), "utf8")).toBe("made\n");
    expect(readdirSync(join(stateOf(repo), "pending"))).toEqual([]);
  }, TIMEOUT * 4);

  test("a file the command deletes in the sandbox comes back on the next run's push (V5, V9)", async () => {
    const repo = makeRepo("sandbox-delete");
    writeFileSync(join(repo, "a.txt"), "kept\n");
    // Run 1 pushes a.txt, then the command deletes it in the sandbox. This machine keeps its copy.
    expect((await runRemote(repo, "rm a.txt")).code).toBe(0);
    expect(readFileSync(join(repo, "a.txt"), "utf8")).toBe("kept\n");
    // Run 2 sees the file: run 1's bring-back noticed it was gone, so the push sends it again.
    const next = await runRemote(repo, "cat a.txt");
    expect(next.code).toBe(0);
    expect(next.stdout).toContain("kept");
  }, TIMEOUT * 2);

  test("AC-35 (a, c): a file the command installs with an old mtime comes back, and zig-out/other stays on the sandbox", async () => {
    const repo = makeRepo("ac-35-old-mtime");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const result = await spawnRemote(
      repo,
      "mkdir -p zig-out/bin zig-out/other && echo app > zig-out/bin/fx && TZ=UTC touch -t 200109090146.40 zig-out/bin/fx && echo x > zig-out/other/x",
      [],
      ["zig-out/bin"],
    ).result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("app\n");
    expect(existsSync(join(repo, "zig-out", "other", "x"))).toBe(false);
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 2);

  test("AC-35 (b): the next run's push does not delete a file that a bring-back brought back", async () => {
    const repo = makeRepo("ac-35-delete-list");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const first = await spawnRemote(repo, "mkdir -p zig-out/bin && echo app > zig-out/bin/fx", [], ["zig-out/bin"]).result;
    expect(first.stderr).toBe(ranLine(1));
    const app = join(runner.api.remotePath(repo), "zig-out", "bin", "fx");
    const next = await spawnRemote(repo, "true", [], ["zig-out/bin"]).result;
    expect(next.code).toBe(0);
    // A delete list that named the file would have removed it from the sandbox. The list's text is inside
    // the push's tar, which the fake does not log, so its effect is what is checked.
    expect(existsSync(app)).toBe(true);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("app\n");
    expect(next.stderr).toBe(ranLine(0));
  }, TIMEOUT * 2);

  test("AC-35 (f): two overlapping runs both write zig-out/bin/fx; the one that finishes second writes its own version, with no N9", async () => {
    const repo = makeRepo("ac-35-both-write");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const sandboxRoot = runner.api.remotePath(repo);
    const before = runner.api.log.length;
    const first = spawnRemote(
      repo,
      "mkdir -p zig-out/bin && while [ ! -e .git/go ]; do sleep 0.05; done && echo A > zig-out/bin/fx && while [ ! -e .git/stop ]; do sleep 0.05; done",
      [],
      ["zig-out/bin"],
    );
    await waitFor(() => execsSince(before) >= 1);
    const second = await spawnRemote(repo, "mkdir -p zig-out/bin && echo B > zig-out/bin/fx", [], ["zig-out/bin"]).result;
    expect(second.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("B\n");
    expect(second.stderr).toBe(ranLine(1));
    // A writes after B has brought its file back, so the sandbox holds A's version when A finishes.
    writeFileSync(join(sandboxRoot, ".git", "go"), "");
    await waitFor(() => readFileSync(join(sandboxRoot, "zig-out", "bin", "fx"), "utf8") === "A\n");
    writeFileSync(join(sandboxRoot, ".git", "stop"), "");
    const firstResult = await first.result;
    expect(firstResult.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("A\n");
    expect(firstResult.stderr).toBe(ranLine(1));
  }, TIMEOUT * 3);

  test("AC-35 (e): a run stopped after its command wrote zig-out/bin/fx leaves the Mac file, changed since, to the next run, whose command does not touch it", async () => {
    const repo = makeRepo("ac-35-stopped-mac-edit");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    mkdirSync(join(repo, "zig-out", "bin"), { recursive: true });
    writeFileSync(join(repo, "zig-out", "bin", "fx"), "before\n");
    const sandboxApp = join(runner.api.remotePath(repo), "zig-out", "bin", "fx");
    const stopped = spawnRemote(repo, "mkdir -p zig-out/bin && echo from-stopped-run > zig-out/bin/fx && sleep 30", [], ["zig-out/bin"]);
    await waitFor(() => existsSync(sandboxApp));
    writeFileSync(join(repo, "zig-out", "bin", "fx"), "mac edit\n");
    stopped.child.kill("SIGTERM");
    expect((await stopped.result).code).toBe(143);
    const next = await spawnRemote(repo, "true", [], ["zig-out/bin"]).result;
    expect(next.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("mac edit\n");
  }, TIMEOUT * 3);

  test("AC-35 (g): an overlapping run's file, written before that run is stopped, comes back with this run, with no N9", async () => {
    const repo = makeRepo("ac-35-overlap-stopped");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const sandboxRoot = runner.api.remotePath(repo);
    const before = runner.api.log.length;
    const thisRun = spawnRemote(repo, "while [ ! -e .git/stop ]; do sleep 0.05; done", [], ["zig-out/bin"]);
    await waitFor(() => execsSince(before) >= 1);
    const overlap = spawnRemote(repo, "mkdir -p zig-out/bin && echo O > zig-out/bin/fx && sleep 30", [], ["zig-out/bin"]);
    await waitFor(() => execsSince(before) >= 2 && existsSync(join(sandboxRoot, "zig-out", "bin", "fx")));
    overlap.child.kill("SIGTERM");
    expect((await overlap.result).code).toBe(143);
    writeFileSync(join(sandboxRoot, ".git", "stop"), "");
    const result = await thisRun.result;
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("O\n");
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 3);

  test("AC-35 (h): a bring-back that times out on the lock keeps the baseline, and the next run brings the file back", async () => {
    const repo = makeRepo("ac-35-lock");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const before = runner.api.log.length;
    const run = spawnRemote(repo, "mkdir -p zig-out/bin && echo app > zig-out/bin/fx && sleep 2", [], ["zig-out/bin"]);
    await waitFor(() => execsSince(before) >= 1);
    // Another process holds the state folder's lock (flock(2), the lock the product takes) while the command ends.
    // The bring-back waits 60 s, then gives up. The holder prints once it holds the lock, and the test waits for that.
    const lockPath = join(stateOf(repo), "lock");
    writeFileSync(lockPath, "", { mode: 0o600 });
    const holder = spawn("perl", ["-MFcntl=:flock", "-e", '$| = 1; open my $fh, ">>", $ARGV[0] or die; flock($fh, LOCK_EX) or die; print "locked\\n"; sleep 75;', lockPath], { stdio: ["ignore", "pipe", "ignore"] });
    children.push(holder);
    const holderExit = new Promise<void>((resolve) => holder.once("exit", () => resolve()));
    await new Promise<void>((resolve) => {
      holder.stdout?.once("data", () => resolve());
      holder.once("exit", () => resolve());
    });
    const timedOut = await run.result;
    expect(timedOut.stderr).not.toContain(ranLine(1));
    expect(existsSync(join(repo, "zig-out", "bin", "fx"))).toBe(false);
    // The bring-back has given up, so the holder lets go of the lock now instead of sleeping on to 75 s.
    holder.kill("SIGKILL");
    await holderExit;
    const next = await spawnRemote(repo, "true", [], ["zig-out/bin"]).result;
    expect(readFileSync(join(repo, "zig-out", "bin", "fx"), "utf8")).toBe("app\n");
    expect(next.stderr).toBe(ranLine(1));
  }, TIMEOUT * 5);

  test("a pending run whose stamp is gone from the sandbox is dropped, and the run still brings back its own files (V9)", async () => {
    const repo = makeRepo("pending-missing");
    const before = runner.api.log.length;
    const stopping = spawnRemote(repo, "sleep 30");
    await waitFor(() => execsSince(before) >= 1);
    stopping.child.kill("SIGTERM");
    expect((await stopping.result).code).toBe(143);
    const pending = join(stateOf(repo), "pending");
    const runId = readdirSync(pending)[0]!;
    rmSync(join(runner.api.remotePath(repo), ".git", `fx-stamp-${runId}`), { force: true });
    const result = await runRemote(repo, "echo kept > own.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "own.txt"), "utf8")).toBe("kept\n");
    expect(existsSync(join(pending, runId))).toBe(false);
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 4);

  test("two runs in one repository at once: the second brings back the first run's file, and the first brings back its later write (V9)", async () => {
    const repo = makeRepo("overlap");
    git(repo, ["init", "-q"]);
    const sandboxRoot = runner.api.remotePath(repo);
    const before = runner.api.log.length;
    const first = spawnRemote(
      repo,
      "while [ ! -e .git/go ]; do sleep 0.05; done; echo a > a.txt; while [ ! -e .git/stop ]; do sleep 0.05; done; echo a2 > a.txt",
    );
    await waitFor(() => execsSince(before) >= 1);
    const second = spawnRemote(repo, ": > .git/started2; while [ ! -e a.txt ]; do sleep 0.05; done; echo b > b.txt");
    await waitFor(() => execsSince(before) >= 2);
    // V9: a run's stamp is taken when its command starts. Run 2's command writes .git/started2 first, so its stamp is
    // in place before run 1 writes a.txt, and that file belongs to run 2.
    await waitFor(() => existsSync(join(sandboxRoot, ".git", "started2")));
    writeFileSync(join(sandboxRoot, ".git", "go"), "");
    const secondResult = await second.result;
    expect(secondResult.code).toBe(0);
    expect(readFileSync(join(repo, "a.txt"), "utf8")).toBe("a\n");
    expect(readFileSync(join(repo, "b.txt"), "utf8")).toBe("b\n");
    expect(secondResult.stderr).toBe(ranLine(2));

    writeFileSync(join(sandboxRoot, ".git", "stop"), "");
    const firstResult = await first.result;
    expect(firstResult.code).toBe(0);
    expect(readFileSync(join(repo, "a.txt"), "utf8")).toBe("a2\n");
    expect(firstResult.stderr).toBe(ranLine(1));
    // AC-23: no push (a fs/write) and no bring-back ran at the same time in the fake log.
    const runLog = runner.api.log.slice(before);
    const pushes = runLog.filter((entry) => entry.route === "write" && entry.endAt !== undefined);
    const brings = runLog.filter((entry) => entry.kind === "bring_back" && entry.endAt !== undefined);
    expect(brings.length).toBeGreaterThanOrEqual(2);
    const overlaps = pushes.flatMap((push) =>
      brings.filter((back) => push.at < back.endAt! && back.at < push.endAt!).map((back) => [push.seq, back.seq]),
    );
    expect(overlaps).toEqual([]);
    const manifest = JSON.parse(readFileSync(join(stateOf(repo), "manifest.json"), "utf8")) as {
      brought: Record<string, { size: number; sha256: string }>;
    };
    expect(manifest.brought["a.txt"]).toMatchObject({ size: 3, sha256: createHash("sha256").update("a2\n").digest("hex") });
    expect(manifest.brought["b.txt"]).toMatchObject({ size: 2, sha256: createHash("sha256").update("b\n").digest("hex") });
  }, TIMEOUT * 4);

  test("an ignored output under a bring-back root that run 1 brought back is updated by run 2 (V9)", async () => {
    const repo = makeRepo("root-updated");
    git(repo, ["init", "-q"]);
    writeFileSync(join(repo, ".gitignore"), "zig-out/\n");
    const first = await spawnRemote(repo, "mkdir -p zig-out/bin && echo v1 > zig-out/bin/app", [], ["zig-out/bin"]).result;
    expect(first.stderr).toBe(ranLine(1));
    const second = await spawnRemote(repo, "echo v2 > zig-out/bin/app", [], ["zig-out/bin"]).result;
    expect(second.code).toBe(0);
    expect(readFileSync(join(repo, "zig-out", "bin", "app"), "utf8")).toBe("v2\n");
    expect(second.stderr).toBe(ranLine(1));
  }, TIMEOUT * 4);

  test("--vcpus goes into the create body, and the sandbox is created with a size (V3)", async () => {
    const repo = makeRepo("vcpus-create");
    const before = runner.api.log.length;
    const result = await spawnRemote(repo, "true", [], [], ["--vcpus", "2"]).result;
    expect(result.code).toBe(0);
    const create = runner.api.log.slice(before).find((entry) => entry.route === "createSandbox");
    expect((create?.body as { resources?: unknown } | undefined)?.resources).toEqual({ vcpus: 2 });
  }, TIMEOUT * 2);

  test("AC-36: vcpus 8 goes into the create body, and sandbox.json holds 8 (V3)", async () => {
    const repo = makeRepo("vcpus-8");
    const before = runner.api.log.length;
    const result = await spawnRemote(repo, "true", [], [], ["--vcpus", "8"]).result;
    expect(result.code).toBe(0);
    const create = runner.api.log.slice(before).find((entry) => entry.route === "createSandbox");
    expect((create?.body as { resources?: unknown } | undefined)?.resources).toEqual({ vcpus: 8 });
    expect(JSON.parse(readFileSync(join(stateOf(repo), "sandbox.json"), "utf8")).vcpus).toBe(8);
  }, TIMEOUT * 2);

  test("AC-36: an isolated run's create body carries vcpus 8 (V3)", async () => {
    const repo = makeRepo("vcpus-isolated");
    const before = runner.api.log.length;
    const result = await spawnRemote(repo, "touch new.txt", [], [], ["--vcpus", "8", "--profile", "media", "--network", "deny-all"], "isolated").result;
    expect(result.code).toBe(0);
    const create = runner.api.log.slice(before).find((entry) => entry.route === "createSandbox");
    expect((create?.body as { resources?: unknown } | undefined)?.resources).toEqual({ vcpus: 8 });
  }, TIMEOUT * 4);

  test("a pending record that cannot be written prints N25 and keeps the exit code (V9)", async () => {
    const repo = makeRepo("pending-blocked");
    expect((await runRemote(repo, "true")).code).toBe(0);
    writeFileSync(join(stateOf(repo), "pending"), "not a folder");
    const before = runner.api.log.length;
    const stopping = spawnRemote(repo, "sleep 30");
    await waitFor(() => execsSince(before) >= 1);
    stopping.child.kill("SIGTERM");
    const stopped = await stopping.result;
    expect(stopped.code).toBe(143);
    expect(stopped.stderr).toContain("fx: could not record the files this run left in the sandbox: ");
    expect(stopped.stderr).toContain("; the next run may not bring them back\n");
  }, TIMEOUT * 4);

  test("a damaged sync record is reset with N26, and the sandbox gets a new generation (V5)", async () => {
    const repo = makeRepo("record-reset");
    writeFileSync(join(repo, "a.txt"), "one\n");
    expect((await runRemote(repo, "true")).code).toBe(0);
    const marker = join(runner.api.remotePath(repo), ".git", "fx-generation");
    const generation = readFileSync(marker, "utf8");
    writeFileSync(join(stateOf(repo), "manifest.json"), "{not json");
    const result = await runRemote(repo, "cat a.txt > seen.txt");
    expect(result.code).toBe(0);
    expect(result.stderr).toBe(
      `fx: the sync record for this repository could not be read and was reset; all files are sent again\n${ranLine(1)}`,
    );
    expect(readFileSync(marker, "utf8")).not.toBe(generation);
    expect(readFileSync(join(repo, "seen.txt"), "utf8")).toBe("one\n");
  }, TIMEOUT * 4);

  // The names a bring-back command streamed back: its base64 stdout, decoded as a tar.gz (V9).
  async function streamedBackNames(runner: RemoteSetupFixture, entries: Array<Record<string, unknown>>): Promise<string[]> {
    const names: string[] = [];
    for (const entry of entries) {
      if (entry.route !== "cmd" || entry.kind !== "bring_back" || typeof entry.commandId !== "string") continue;
      const session = String(entry.path).replace(/\/cmd$/, "");
      const response = await fetch(`${runner.api.url}${session}/cmd/${entry.commandId}/logs?teamId=${fakeTeam.id}`, {
        headers: { authorization: `Bearer ${fakeApiToken}` },
      });
      const lines = (await response.text())
        .split("\n")
        .filter((line) => line.length > 0)
        .map((line) => JSON.parse(line) as { stream?: string; data?: string });
      const base64 = lines.filter((line) => line.stream === "stdout").map((line) => line.data ?? "").join("");
      names.push(...tarEntries(Buffer.from(base64, "base64")).map((item) => item.name.replace(/^\.\//, "")));
    }
    return names;
  }

  test("a bring-back after a stopped run skips the files the push sent: none streams, writes, or counts, and their mtimes stay (V9)", async () => {
    const repo = makeRepo("identical-after-stop");
    const names = ["a1.txt", "a2.txt", "a3.txt"];
    for (const name of names) writeFileSync(join(repo, name), "v1\n");
    expect((await runRemote(repo, "true")).code).toBe(0);
    const before = runner.api.log.length;
    const stopping = spawnRemote(repo, "sleep 30");
    await waitFor(() => execsSince(before) >= 1);
    stopping.child.kill("SIGTERM");
    expect((await stopping.result).code).toBe(143);
    for (const name of names) writeFileSync(join(repo, name), "v2, changed\n");
    const mtimes = () => names.map((name) => statSync(join(repo, name)).mtimeMs);
    const mtimesBefore = mtimes();
    const runFrom = runner.api.log.length;
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    const streamed = await streamedBackNames(runner, runner.api.log.slice(runFrom) as Array<Record<string, unknown>>);
    expect(streamed).toEqual([]);
    expect(result.stderr).toBe(ranLine(0));
    expect(mtimes()).toEqual(mtimesBefore);
    for (const name of names) expect(readFileSync(join(repo, name), "utf8")).toBe("v2, changed\n");
  }, TIMEOUT * 4);

  // The host key the runner derives for the test user on this machine (I1).
  const hostPrefix = () => `fx-iso-${createHash("sha256").update(`usr_fake\n${hostname()}`).digest("hex").slice(0, 8)}-`;

  test("AC-15: an isolated run creates a non-persistent deny-all sandbox, sends no env, deletes it, and keeps new.txt in runs (I2 to I4)", async () => {
    const repo = makeRepo("isolated-basic");
    const before = runner.api.log.length;
    const result = await spawnRemote(repo, "touch new.txt", [], [], ["--profile", "media", "--network", "deny-all"], "isolated").result;
    expect(result.code).toBe(0);
    const later = runner.api.log.slice(before);
    const create = later.find((entry) => entry.route === "createSandbox")?.body as { name: string; persistent: boolean; timeout: number; networkPolicy: unknown } | undefined;
    expect(create?.persistent).toBe(false);
    expect(create?.timeout).toBe(2_700_000);
    expect(create?.networkPolicy).toEqual({ mode: "deny-all" });
    expect(create?.name).toMatch(/^fx-iso-[0-9a-f]{8}-[0-9a-f]{12}$/);
    const exec = later.find((entry) => entry.route === "cmd" && entry.kind === "exec")?.body as { env?: unknown } | undefined;
    expect(exec?.env).toEqual({});
    expect(later.some((entry) => entry.route === "deleteSandbox" && entry.path === `/v2/sandboxes/${create?.name}`)).toBe(true);
    expect(existsSync(join(repo, "new.txt"))).toBe(false);
    const [runId] = readdirSync(join(stateOf(repo), "runs"));
    expect(existsSync(join(stateOf(repo), "runs", runId!, "new.txt"))).toBe(true);
    expectIsolatedRan(result.stderr, 1);
  }, TIMEOUT * 2);

  test("AC-16: a core.fsmonitor in the repository's config never runs, in a remote run or an isolated one (V9, R4.4)", async () => {
    const repo = makeRepo("fsmonitor");
    git(repo, ["init", "-q"]);
    const marker = join(runRoot, "fsmonitor-marker");
    const script = join(runRoot, "fsmonitor.sh");
    writeFileSync(script, `#!/bin/sh\necho ran > ${marker}\nexit 1\n`);
    chmodSync(script, 0o755);
    git(repo, ["config", "core.fsmonitor", script]);
    const command = "git status >/dev/null 2>&1; true";
    expect((await runRemote(repo, command)).code).toBe(0);
    expect(readFileSync(join(runner.api.remotePath(repo), ".git", "config"), "utf8")).not.toContain("fsmonitor");
    expect((await spawnRemote(repo, command, [], [], ["--profile", "media"], "isolated").result).code).toBe(0);
    expect(existsSync(marker)).toBe(false);
  }, TIMEOUT * 4);

  test("AC-31: the sweep deletes only this host's sandbox older than an hour, and a failed list lets the run go on (I1)", async () => {
    const hour = 60 * 60 * 1000;
    const prefix = hostPrefix();
    const here = { teamId: fakeTeam.id, projectId: fakeTeam.projects[0]!.id };
    runner.api.seedSandbox({ name: `${prefix}old`, createdAt: Date.now() - 2 * hour, status: "stopped", ...here });
    runner.api.seedSandbox({ name: `${prefix}live`, createdAt: Date.now() - 2 * hour, status: "running", ...here });
    runner.api.seedSandbox({ name: `${prefix}new`, createdAt: Date.now() - 10 * 60 * 1000, status: "stopped", ...here });
    runner.api.seedSandbox({ name: "fx-iso-other-x", createdAt: Date.now() - 2 * hour, status: "stopped", ...here });
    const before = runner.api.log.length;
    const first = await spawnRemote(makeRepo("sweep-first"), "true", [], [], ["--profile", "media"], "isolated").result;
    expect(first.code).toBe(0);
    const later = runner.api.log.slice(before);
    const list = later.find((entry) => entry.route === "listSandboxes");
    expect(list?.query).toMatchObject({ sortBy: "name", namePrefix: prefix });
    const deleted = later.filter((entry) => entry.route === "deleteSandbox").map((entry) => entry.path);
    expect(deleted).toContain(`/v2/sandboxes/${prefix}old`);
    expect(deleted.some((path) => path.includes(`${prefix}new`) || path.includes(`${prefix}live`) || path.includes("fx-iso-other-x"))).toBe(false);

    runner.api.faults.listFails = true;
    const secondFrom = runner.api.log.length;
    const second = await spawnRemote(makeRepo("sweep-second"), "true", [], [], ["--profile", "media"], "isolated").result;
    expect(second.code).toBe(0);
    expectIsolatedRan(second.stderr, 0);
    expect(runner.api.log.slice(secondFrom).some((entry) => entry.route === "createSandbox")).toBe(true);
  }, TIMEOUT * 4);

  test("a stop during an isolated run still deletes its sandbox (I4)", async () => {
    const repo = makeRepo("isolated-stop");
    const before = runner.api.log.length;
    const run = spawnRemote(repo, "sleep 30", [], [], ["--profile", "media"], "isolated");
    await waitFor(() => runner.api.log.slice(before).some((entry) => entry.route === "cmd" && entry.kind === "exec" && JSON.stringify(entry.body).includes("fx-stamp-")));
    run.child.kill("SIGTERM");
    expect((await run.result).code).toBe(143);
    const later = runner.api.log.slice(before);
    const name = (later.find((entry) => entry.route === "createSandbox")?.body as { name: string } | undefined)?.name;
    expect(name).toBeDefined();
    expect(later.some((entry) => entry.route === "deleteSandbox" && entry.path === `/v2/sandboxes/${name}`)).toBe(true);
  }, TIMEOUT * 2);

  test("a non-zero exit in an isolated run still brings its files back (I3)", async () => {
    const repo = makeRepo("isolated-failing");
    const result = await spawnRemote(repo, "echo failed > report.txt; exit 3", [], [], ["--profile", "media"], "isolated").result;
    expect(result.code).toBe(3);
    const [runId] = readdirSync(join(stateOf(repo), "runs"));
    expect(readFileSync(join(stateOf(repo), "runs", runId!, "report.txt"), "utf8")).toBe("failed\n");
    expectIsolatedRan(result.stderr, 1);
  }, TIMEOUT * 2);

  test("N18: a size the sandbox reports differently from the request is noted once (V3)", async () => {
    const repo = makeRepo("size-note");
    expect((await runRemote(repo, "true")).code).toBe(0);
    runner.api.faults.reportedVcpus = 2;
    try {
      const result = await spawnRemote(repo, "true", [], [], ["--vcpus", "4"]).result;
      expect(result.code).toBe(0);
      expect(result.stderr).toBe(`fx: vcpus 4 applies from the next session of this repository's sandbox; it now has 2\n${ranLine(0)}`);
    } finally {
      runner.api.faults.reportedVcpus = undefined;
    }
  }, TIMEOUT * 2);

  test("AC-36: a kept sandbox at 8 is patched to 4 once, with N18 while it still reports 8, and the run after sends no PATCH (V3)", async () => {
    const repo = makeRepo("size-patch");
    const createFrom = runner.api.log.length;
    expect((await spawnRemote(repo, "true", [], [], ["--vcpus", "8"]).result).code).toBe(0);
    const create = runner.api.log.slice(createFrom).find((entry) => entry.route === "createSandbox");
    expect((create?.body as { resources?: unknown } | undefined)?.resources).toEqual({ vcpus: 8 });

    runner.api.faults.reportedVcpus = 8;
    const patchFrom = runner.api.log.length;
    try {
      const patched = await spawnRemote(repo, "true", [], [], ["--vcpus", "4"]).result;
      expect(patched.code).toBe(0);
      expect(patched.stderr).toBe(`fx: vcpus 4 applies from the next session of this repository's sandbox; it now has 8\n${ranLine(0)}`);
    } finally {
      runner.api.faults.reportedVcpus = undefined;
    }
    const patches = runner.api.log.slice(patchFrom).filter((entry) => entry.route === "updateSandbox");
    expect(patches).toHaveLength(1);
    expect((patches[0]!.body as { resources?: { vcpus?: number } }).resources?.vcpus).toBe(4);

    const nextFrom = runner.api.log.length;
    const next = await spawnRemote(repo, "true", [], [], ["--vcpus", "4"]).result;
    expect(next.code).toBe(0);
    expect(runner.api.log.slice(nextFrom).some((entry) => entry.route === "updateSandbox")).toBe(false);
  }, TIMEOUT * 3);

  test("an isolated run whose new sandbox has under 30 minutes left extends it before the command runs (I2, V12)", async () => {
    runner.api.faults.nextSessionMs = 10 * 60 * 1000;
    const before = runner.api.log.length;
    const result = await spawnRemote(makeRepo("isolated-extend"), "true", [], [], ["--profile", "media"], "isolated").result;
    expect(result.code).toBe(0);
    const later = runner.api.log.slice(before);
    const extendAt = later.findIndex((entry) => entry.route === "extendTimeout");
    const execAt = later.findIndex((entry) => entry.route === "cmd" && entry.kind === "exec" && JSON.stringify(entry.body).includes("fx-stamp-"));
    expect(execAt).toBeGreaterThanOrEqual(0);
    expect(extendAt).toBeGreaterThanOrEqual(0);
    expect(extendAt).toBeLessThan(execAt);
  }, TIMEOUT * 2);

  test("a command that writes 3,000 files brings back 2,000 and defers 1,000, which the next run brings back (V9)", async () => {
    const repo = makeRepo("defer-cap");
    try {
      const first = await runRemote(repo, "for i in $(seq 1 3000); do echo $i > f$i.txt; done");
      expect(first.code).toBe(0);
      expect(first.stderr).toBe(`fx: 1000 files not brought back: past this run's limit of 2,000 files or 64 MiB; the next run brings them back\n${ranLine(2000)}`);
      expect(readdirSync(repo).filter((name) => name.endsWith(".txt"))).toHaveLength(2000);
      const manifest = JSON.parse(readFileSync(join(stateOf(repo), "manifest.json"), "utf8")) as { pending_back: string[] };
      expect(manifest.pending_back).toHaveLength(1000);
      const second = await runRemote(repo, "true");
      expect(second.code).toBe(0);
      expect(readdirSync(repo).filter((name) => name.endsWith(".txt"))).toHaveLength(3000);
      expect(second.stderr).toBe(ranLine(1000));
    } finally {
      discardRepo(repo);
    }
  }, TIMEOUT * 6);

  test("a pending run with a big push still brings this run's own output back (V9)", async () => {
    const repo = makeRepo("pending-big-push");
    try {
      expect((await runRemote(repo, "true")).code).toBe(0);
      const stopping = spawnRemote(repo, "echo made > made.txt; sleep 30");
      await waitFor(() => existsSync(join(runner.api.remotePath(repo), "made.txt")));
      stopping.child.kill("SIGTERM");
      expect((await stopping.result).code).toBe(143);
      for (let index = 0; index < 2100; index++) writeFileSync(join(repo, `pushed-${index}.txt`), `${index}\n`);
      const result = await runRemote(repo, "echo own > own.txt");
      expect(result.code).toBe(0);
      expect(readFileSync(join(repo, "own.txt"), "utf8")).toBe("own\n");
      expect(readFileSync(join(repo, "made.txt"), "utf8")).toBe("made\n");
      expect(result.stderr).toBe(ranLine(2));
    } finally {
      discardRepo(repo);
    }
  }, TIMEOUT * 6);

  test("a command that exits 125 itself still brings its files back (L6)", async () => {
    const repo = makeRepo("own-125");
    const result = await runRemote(repo, "echo kept > kept.txt; exit 125");
    expect(result.code).toBe(125);
    expect(readFileSync(join(repo, "kept.txt"), "utf8")).toBe("kept\n");
    expect(result.stderr).toBe(ranLine(1));
  }, TIMEOUT * 2);

  test("a session that ends on the push is resumed once, and the run goes on with its file back (V3)", async () => {
    const repo = makeRepo("resume-410");
    expect((await runRemote(repo, "true")).code).toBe(0);
    writeFileSync(join(repo, "changed.txt"), "changed\n");
    runner.api.faults.goneOnce = true;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo resumed > resumed.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "resumed.txt"), "utf8")).toBe("resumed\n");
    expect(result.stderr).toBe(ranLine(1));
    const later = runner.api.log.slice(before);
    expect(later.some((entry) => entry.notes.some((note) => note.startsWith("resumed as")))).toBe(true);
    expect(later.filter((entry) => entry.route === "createSandbox")).toHaveLength(0);
  }, TIMEOUT * 2);

  test("a resume that answers 404 creates the sandbox once, and the run goes on with its file back (V3)", async () => {
    const repo = makeRepo("recreate-410");
    expect((await runRemote(repo, "true")).code).toBe(0);
    writeFileSync(join(repo, "changed.txt"), "changed\n");
    runner.api.faults.goneOnce = true;
    runner.api.faults.sandboxGone = true;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo recreated > recreated.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "recreated.txt"), "utf8")).toBe("recreated\n");
    expect(result.stderr).toBe(ranLine(1));
    expect(runner.api.log.slice(before).filter((entry) => entry.route === "createSandbox")).toHaveLength(1);
  }, TIMEOUT * 3);

  test("an extend answered 410 before exec recovers the session once, and the run goes on with its file back (V3, V12)", async () => {
    runner.api.faults.nextSessionMs = 10 * 60 * 1000;
    const repo = makeRepo("extend-410");
    expect((await runRemote(repo, "true")).code).toBe(0);
    runner.api.faults.goneOnce = true;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo extended > extended.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "extended.txt"), "utf8")).toBe("extended\n");
    expect(result.stderr).toBe(ranLine(1));
    const later = runner.api.log.slice(before);
    expect(later.filter((entry) => entry.route === "extendTimeout")).toHaveLength(2);
    expect(later.some((entry) => entry.notes.some((note) => note.startsWith("resumed as")))).toBe(true);
    expect(later.filter((entry) => entry.route === "createSandbox")).toHaveLength(0);
  }, TIMEOUT * 2);

  test("an extend before exec gets no resume once the push has used the run's one: the run is refused with N1, and the start request is not sent (V3, V12)", async () => {
    runner.api.faults.nextSessionMs = 10 * 60 * 1000;
    const repo = makeRepo("extend-after-resume");
    expect((await runRemote(repo, "true")).code).toBe(0);
    writeFileSync(join(repo, "changed.txt"), "changed\n");
    runner.api.faults.nextSessionMs = 10 * 60 * 1000;
    runner.api.faults.goneWrites = 1;
    runner.api.faults.goneExtends = 1;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo ran > ran.txt");
    expect(result.code).toBe(125);
    expect(result.stderr).toContain("fx: did not run: the Vercel sandbox could not start: 410 the session ended before the command started; run it again\n");
    const later = runner.api.log.slice(before);
    expect(later.filter((entry) => entry.notes.some((note) => note.startsWith("resumed as")))).toHaveLength(1);
    expect(later.filter((entry) => entry.route === "extendTimeout")).toHaveLength(1);
    // The marker read is also a `cmd` request, so the start request is found by its command text.
    expect(later.some((entry) => JSON.stringify(entry.body ?? "").includes("ran.txt"))).toBe(false);
    expect(existsSync(join(repo, "ran.txt"))).toBe(false);
  }, TIMEOUT * 2);

  test("a second 410 on the same push, after one recovery, is refused with N2, and the write is not sent a third time (V3)", async () => {
    const repo = makeRepo("second-410");
    expect((await runRemote(repo, "true")).code).toBe(0);
    writeFileSync(join(repo, "changed.txt"), "changed\n");
    runner.api.faults.goneWrites = 2;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo never > never.txt");
    expect(result.code).toBe(125);
    expect(result.stderr).toBe("fx: did not run: sending files failed: the sandbox session ended\n");
    expect(existsSync(join(repo, "never.txt"))).toBe(false);
    const later = runner.api.log.slice(before);
    expect(later.filter((entry) => entry.route === "write")).toHaveLength(2);
    expect(later.filter((entry) => entry.route === "getSandbox")).toHaveLength(1);
  }, TIMEOUT * 2);

  test("an exec answered 410 before its command line resumes once, sends the command again, and the command runs (V3, V6)", async () => {
    const repo = makeRepo("exec-410");
    expect((await runRemote(repo, "true")).code).toBe(0);
    await stopSandboxSession(repo);
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo ran > ran.txt");
    expect(result.code).toBe(0);
    expect(readFileSync(join(repo, "ran.txt"), "utf8")).toBe("ran\n");
    expect(result.stderr).toBe(ranLine(1));
    const later = runner.api.log.slice(before);
    expect(commandStatuses(later, "ran.txt")).toEqual([410, 200]);
    expect(later.filter((entry) => entry.route === "getSandbox")).toHaveLength(1);
    expect(later.some((entry) => entry.route === "createSandbox")).toBe(false);
  }, TIMEOUT * 2);

  test("a second 410 on the resent exec is refused with N1, and the next run resumes before its first call and succeeds (V3, V6)", async () => {
    const repo = makeRepo("exec-410-twice");
    expect((await runRemote(repo, "true")).code).toBe(0);
    await stopSandboxSession(repo);
    runner.api.faults.goneCommand = "never.txt";
    runner.api.faults.goneCommandTimes = 2;
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo never > never.txt");
    expect(result.code).toBe(125);
    expect(result.stderr).toBe("fx: did not run: the Vercel sandbox could not start: 410 the session ended before the command started; run it again\n");
    expect(existsSync(join(repo, "never.txt"))).toBe(false);
    const refused = runner.api.log.slice(before);
    expect(commandStatuses(refused, "never.txt")).toEqual([410, 410]);
    expect(refused.filter((entry) => entry.route === "getSandbox")).toHaveLength(1);

    const next = runner.api.log.length;
    const later = await runRemote(repo, "echo next > next.txt");
    expect(later.code).toBe(0);
    expect(readFileSync(join(repo, "next.txt"), "utf8")).toBe("next\n");
    const calls = runner.api.log.slice(next);
    const resumeAt = calls.findIndex((entry) => entry.route === "getSandbox");
    const firstCommandAt = calls.findIndex((entry) => entry.route === "cmd");
    expect(resumeAt).toBeGreaterThanOrEqual(0);
    expect(resumeAt).toBeLessThan(firstCommandAt);
    expect(calls.some((entry) => entry.route === "createSandbox")).toBe(false);
  }, TIMEOUT * 3);

  test("AC-8: a sandbox that cannot be created refuses with N1 with status 500, and the command never runs on this machine", async () => {
    const repo = makeRepo("create-500");
    runner.api.faults.createStatus = 500;
    const result = await runRemote(repo, "touch local-marker");
    expect(result.code).toBe(125);
    expect(result.stderr).toContain("fx: did not run: the Vercel sandbox could not start: 500 ");
    expect(existsSync(join(repo, "local-marker"))).toBe(false);
  }, TIMEOUT * 2);

  test("V13: a create answered 403 is refused with N11 naming the login, and the command never runs here", async () => {
    const repo = makeRepo("create-403");
    runner.api.faults.createStatus = 403;
    const result = await runRemote(repo, "touch local-marker");
    expect(result.code).toBe(125);
    expect(result.stderr).toBe("fx: did not run: Vercel rejected the login (403). Run `vercel whoami` or `vercel login`.\n");
    expect(existsSync(join(repo, "local-marker"))).toBe(false);
  }, TIMEOUT * 2);

  test("V13: an exec answered 403 before its command line is refused with N11, sent once, and the command never runs here", async () => {
    const repo = makeRepo("exec-403");
    expect((await runRemote(repo, "true")).code).toBe(0);
    const before = runner.api.log.length;
    runner.api.faults.commandStatus = { contains: "touch local-marker", status: 403 };
    const result = await runRemote(repo, "touch local-marker");
    expect(result.code).toBe(125);
    expect(result.stderr).toBe("fx: did not run: Vercel rejected the login (403). Run `vercel whoami` or `vercel login`.\n");
    expect(existsSync(join(repo, "local-marker"))).toBe(false);
    expect(commandStatuses(runner.api.log.slice(before), "touch local-marker")).toEqual([403]);
  }, TIMEOUT * 2);

  test("a create answer fx cannot read is refused with N1 naming the create step, and the command never runs here (V3)", async () => {
    const repo = makeRepo("create-malformed");
    runner.api.faults.createBody = "not json";
    const result = await runRemote(repo, "touch local-marker");
    expect(result.code).toBe(125);
    expect(result.stderr).toContain("fx: did not run: the Vercel sandbox could not start: 200 create: the answer is malformed: the body is not JSON");
    expect(existsSync(join(repo, "local-marker"))).toBe(false);
  }, TIMEOUT * 2);

  test("a create answer that lacks the session start names the field in N1 (V3)", async () => {
    const repo = makeRepo("create-no-start");
    runner.api.faults.createBody = '{"sandbox":{"name":"fx-x","vcpus":2},"session":{"id":"sbx_x","timeout":2700000}}';
    const result = await runRemote(repo, "touch local-marker");
    expect(result.code).toBe(125);
    expect(result.stderr).toContain(
      "fx: did not run: the Vercel sandbox could not start: 200 create: the answer is malformed: session.startedAt is missing",
    );
    expect(existsSync(join(repo, "local-marker"))).toBe(false);
  }, TIMEOUT * 2);

  test("a session that ends on the marker write resumes once, and the run succeeds (V3, V4)", async () => {
    const repo = makeRepo("marker-410");
    runner.api.faults.goneCommand = "fx-generation";
    const before = runner.api.log.length;
    const result = await runRemote(repo, "echo marked");
    expect(result.code).toBe(0);
    expect(result.stdout).toBe("marked\n");
    expect(result.stderr).toBe(ranLine(0));
    expect(runner.api.log.slice(before).filter((entry) => entry.route === "getSandbox" && entry.query.resume === "true")).toHaveLength(1);
  }, TIMEOUT * 2);

  test("N28: a session that ends on the push is recovered, a sandbox that is gone is created again, and the pending runs are named and not brought back (V3, V4)", async () => {
    const repo = makeRepo("replaced-pending");
    expect((await runRemote(repo, "true")).code).toBe(0);
    const stopping = spawnRemote(repo, "echo made > made.txt; sleep 30");
    await waitFor(() => existsSync(join(runner.api.remotePath(repo), "made.txt")));
    stopping.child.kill("SIGTERM");
    expect((await stopping.result).code).toBe(143);
    writeFileSync(join(repo, "changed.txt"), "changed\n");
    runner.api.faults.goneOnce = true;
    runner.api.faults.sandboxGone = true;
    const result = await runRemote(repo, "true");
    expect(result.code).toBe(0);
    expect(result.stderr).toBe(`fx: files from 1 earlier stopped run were not brought back, because the sandbox was replaced or its record was reset\n${ranLine(0)}`);
    expect(existsSync(join(repo, "made.txt"))).toBe(false);
    expect(existsSync(join(stateOf(repo), "pending"))).toBe(false);
  }, TIMEOUT * 4);

  test("10,000 pending names of about 300 bytes travel as data, and the next run brings back 2,000 of them (V9)", async () => {
    const repo = makeRepo("pending-names");
    try {
      const folder = "n".repeat(140);
      const first = await runRemote(repo, `mkdir -p "big/${folder}/${folder}" && for i in $(seq 1 12000); do : > "big/${folder}/${folder}/f$i"; done`);
      expect(first.code).toBe(0);
      expect(first.stderr).toBe(`fx: 10000 files not brought back: past this run's limit of 2,000 files or 64 MiB; the next run brings them back\n${ranLine(2000)}`);
      const manifest = JSON.parse(readFileSync(join(stateOf(repo), "manifest.json"), "utf8")) as { pending_back: string[] };
      expect(manifest.pending_back).toHaveLength(10_000);
      expect(manifest.pending_back[0]!.length).toBeGreaterThan(280);
      const second = await runRemote(repo, "true");
      expect(second.code).toBe(0);
      expect(readdirSync(join(repo, "big", folder, folder))).toHaveLength(4000);
      expect(second.stderr).toBe(`fx: 8000 files not brought back: past this run's limit of 2,000 files or 64 MiB; the next run brings them back\n${ranLine(2000)}`);
    } finally {
      // The 16,000 files of this test are removed inside the test, under its own timeout. Left to the
      // describe's afterAll, their removal took 5.7 s on CI, past Bun's 5 s hook timeout.
      discardRepo(repo);
    }
  }, TIMEOUT * 8);

  test("a pending name whose folder became a link in the sandbox brings back nothing from outside the repository (V9)", async () => {
    const repo = makeRepo("pending-link");
    try {
      expect((await runRemote(repo, "mkdir -p d && for i in $(seq 1 2100); do : > d/f$i; done")).code).toBe(0);
      const manifest = JSON.parse(readFileSync(join(stateOf(repo), "manifest.json"), "utf8")) as { pending_back: string[] };
      expect(manifest.pending_back.length).toBeGreaterThan(0);
      const second = await runRemote(
        repo,
        "rm -rf d && mkdir -p /tmp/fx-link-target && for i in $(seq 1 2100); do echo leak > /tmp/fx-link-target/f$i; done && ln -s /tmp/fx-link-target d",
      );
      expect(second.code).toBe(0);
      // The link `d` is itself a walked entry that is not a regular file, so it counts once more.
      expect(second.stderr).toContain(`fx: ${manifest.pending_back.length + 1} files not brought back: not regular files`);
      const after = JSON.parse(readFileSync(join(stateOf(repo), "manifest.json"), "utf8")) as { pending_back: string[] };
      expect(after.pending_back.filter((name) => manifest.pending_back.includes(name))).toEqual([]);
      for (const name of manifest.pending_back) {
        const path = join(repo, name);
        expect(existsSync(path) && readFileSync(path, "utf8") === "leak\n").toBe(false);
      }
    } finally {
      discardRepo(repo);
      rmSync("/tmp/fx-link-target", { recursive: true, force: true });
    }
  }, TIMEOUT * 4);

  test("N27: an unknown profile argument is refused before anything is created (I2)", async () => {
    const repo = makeRepo("unknown-argument");
    const before = runner.api.log.length;
    const result = await spawnRemote(repo, "true", [], [], ["--profile", "media", "--bogus"], "isolated").result;
    expect(result.code).toBe(125);
    expect(result.stderr).toBe("fx: did not run: profile media has an unknown argument --bogus\n");
    expect(runner.api.log.slice(before).some((entry) => entry.route === "createSandbox")).toBe(false);
  }, TIMEOUT);
});

// The host's text for a placed run (spec L6, N7): the runner's `fx:` lines and the exit
// code reach the model unchanged, and the host adds only its own timeout line.
describe("a placed run's result through the host: the runner's lines pass through (L6, N7)", () => {
  test("a runner refusal reaches the model with its exact line and exit 125, and the host adds no notice", async () => {
    // The first call makes the sandbox; the fake then answers the second call's exec with 410 twice, so the
    // one resume does not cover it and the run is refused (V3, V6).
    let fixtureRef: Fixture | undefined;
    const responses: GatewayResponse[] = [
      fakeGatewayToolCall("call-1", "shell", { command: "true", runner: "remote" }),
      (_body: string) => {
        fixtureRef!.setup.api.faults.goneCommand = "never.txt";
        fixtureRef!.setup.api.faults.goneCommandTimes = 2;
        return fakeGatewayToolCall("call-2", "shell", { command: "echo never > never.txt", runner: "remote" });
      },
      fakeGatewayFinalText("done\n"),
    ];
    await withSandboxFixture(responses, async (fixture) => {
      fixtureRef = fixture;
      const texts = await askSandbox(fixture);
      expect(texts).toContain("fx: did not run: the Vercel sandbox could not start: 410 the session ended before the command started; run it again");
      expect(texts).toContain('"exit_code":125');
      expect(texts).not.toContain('"notice"');
      expect(existsSync(join(fixture.workspace, "never.txt"))).toBe(false);
    });
  }, TIMEOUT * 2);

  test("a command whose own output starts with fx: reaches the model as output, with exit 125, and the host adds nothing", async () => {
    await withSandboxFixture(shellCall({ command: 'echo "fx: did not run: fake" >&2; exit 125', runner: "remote" }), async (fixture) => {
      const texts = await askSandbox(fixture);
      expect(texts).toContain("fx: did not run: fake");
      expect(texts).toContain('"exit_code":125');
      expect(texts).not.toContain('"notice"');
    });
  }, TIMEOUT * 2);

  test("a host timeout on a placed run gives N7 once, and the runner's N5 line says the remote command was killed", async () => {
    // The budget covers the push and setup as well as the command, so it is 5 s. The command sleeps for 30 s, far
    // longer, so the timeout fires while it runs. The check below still needs exactly one N7 line.
    await withSandboxFixture(shellCall({ command: "sleep 30", runner: "remote", timeout_ms: 5000 }), async (fixture) => {
      const texts = await askSandbox(fixture);
      expect(texts.split("fx: timed out after 5000 ms").length - 1).toBe(1);
      expect(texts).toContain("fx: stopped; the remote command was killed");
      // AC-24: the timeout reaches the remote command as a graceful kill (signal 15) before the runner exits.
      expect(apiSince(fixture).some((entry) => entry.route === "kill" && (entry.body as { signal?: number } | null)?.signal === 15)).toBe(true);
    });
  }, TIMEOUT * 3);

  // The id of the last session a request names: the session the most recent shell result began.
  const lastSessionId = (body: string): string => {
    const matches = [...body.matchAll(/\\?"session_id\\?"\s*:\s*\\?"([^"\\]+)/g)];
    const last = matches.at(-1);
    if (!last) throw new Error("the request names no session");
    return last[1]!;
  };

  test("a placed background run that times out gives N7 once, in the notice of the call that reports its end", async () => {
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", { command: "sleep 30", runner: "remote", timeout_ms: 5000, yield_time_ms: 300 }),
        (body: string) =>
          fakeGatewayToolCall("call-2", "shell", { request: { action: "interact", session_id: lastSessionId(body), yield_time_ms: 8000 } }),
        (body: string) =>
          fakeGatewayToolCall("call-3", "shell", { request: { action: "interact", session_id: lastSessionId(body), yield_time_ms: 300 } }),
        fakeGatewayFinalText("done\n"),
      ],
      async (fixture) => {
        // The budget covers the push and setup as well as the command, so it is 5 s. The command sleeps for 30 s.
        const texts = await askSandbox(fixture);
        expect(texts).toContain("TimeoutExpired");
        // The later interact reports the same ended command again, and its notice carries no second line.
        expect(texts.split("fx: timed out after 5000 ms").length - 1).toBe(1);
        expect(texts).toContain("fx: stopped; the remote command was killed");
        expect(apiSince(fixture).some((entry) => entry.route === "kill" && (entry.body as { signal?: number } | null)?.signal === 15)).toBe(true);
      },
    );
  }, TIMEOUT * 3);

  test("a force stop of a placed background run gives N6 once, and a second force stop gives none", async () => {
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", { command: "sleep 30", runner: "remote", yield_time_ms: 300 }),
        (body: string) =>
          fakeGatewayToolCall("call-2", "shell", { request: { action: "stop", session_id: lastSessionId(body), force: true } }),
        (body: string) =>
          fakeGatewayToolCall("call-3", "shell", { request: { action: "stop", session_id: lastSessionId(body), force: true } }),
        fakeGatewayFinalText("done\n"),
      ],
      async (fixture) => {
        const texts = await askSandbox(fixture);
        expect(texts.split("fx: force stop: the remote command may still run in the sandbox").length - 1).toBe(1);
      },
    );
  }, TIMEOUT * 3);

  test("a local background run gets neither N7 nor N6: its own timeout and force stop print no host line", async () => {
    await withSandboxFixture(
      [
        fakeGatewayToolCall("call-1", "shell", { command: "sleep 30", timeout_ms: 1500, yield_time_ms: 300 }),
        (body: string) =>
          fakeGatewayToolCall("call-2", "shell", { request: { action: "interact", session_id: lastSessionId(body), yield_time_ms: 8000 } }),
        fakeGatewayToolCall("call-3", "shell", { command: "sleep 30", yield_time_ms: 300 }),
        (body: string) =>
          fakeGatewayToolCall("call-4", "shell", { request: { action: "stop", session_id: lastSessionId(body), force: true } }),
        fakeGatewayFinalText("done\n"),
      ],
      async (fixture) => {
        const texts = await askSandbox(fixture);
        expect(texts).toContain("TimeoutExpired");
        expect(texts).not.toContain("fx: timed out after");
        expect(texts).not.toContain("fx: force stop");
        expect(execEvents(fixture)).toHaveLength(0);
      },
    );
  }, TIMEOUT * 3);

  test("a session that ends during the first use resumes once, the first use finishes, and the run succeeds (V3, V4)", async () => {
    // The fake ends the session on the first session call, which is the first use's own `id -un`.
    await withSandboxFixture(shellCall({ command: "echo first-use", runner: "remote" }), async (fixture) => {
      fixture.setup.api.faults.goneOnce = true;
      const texts = await askSandbox(fixture);
      expect(texts).toContain("first-use");
      expect(texts).toContain('"exit_code":0');
      expect(texts).not.toContain("did not run");
      expect(apiSince(fixture).filter((entry) => entry.route === "getSandbox" && entry.query.resume === "true")).toHaveLength(1);
    });
  }, TIMEOUT * 2);
});
