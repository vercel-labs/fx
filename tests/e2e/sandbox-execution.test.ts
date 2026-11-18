import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { hostname } from "node:os";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import { type FakeSandboxApi, startFakeSandboxApi } from "./fixtures/fake-sandbox-api";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";

// fx runs the built binary against a fake model gateway and the fake Sandbox
// API in fixtures/fake-sandbox-api.ts. The sandbox runs commands on this
// machine under its own disk folder, so each test can see where a command ran.
const TIMEOUT = 120_000;
const SANDBOX_TOKEN = "sandbox-execution-fake-token";
const GATEWAY_KEY = "sandbox-execution-fake-key";

type Gateway = ReturnType<typeof startFakeGateway>;
type GatewayResponse = Parameters<typeof startFakeGateway>[0][number];
type Rule = { command: string; placement: string };
type ScenarioPaths = { repo: string; disk: string };

type Fixture = {
  root: string;
  home: string;
  repo: string;
  disk: string;
  sandbox: FakeSandboxApi;
  gateway: Gateway;
};

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

// A workspace repository with one committed file, a.txt, and a committed
// .gitignore when `gitignore` is given.
function makeRepo(root: string, gitignore?: string): string {
  const repo = join(root, "repo");
  mkdirSync(repo);
  writeFileSync(join(repo, "a.txt"), "hello\n");
  const committed = ["a.txt"];
  if (gitignore !== undefined) {
    writeFileSync(join(repo, ".gitignore"), gitignore);
    committed.push(".gitignore");
  }
  git(repo, ["init", "-q"]);
  git(repo, ["add", ...committed]);
  git(repo, ["commit", "-q", "-m", "initial"]);
  return repo;
}

// A plain folder, not a repository, with one file, in.txt.
function makePlainFolder(root: string): string {
  const folder = join(root, "repo");
  mkdirSync(folder);
  writeFileSync(join(folder, "in.txt"), "data");
  return folder;
}

// Runs `body` with a temp root holding the profile, the sandbox config with
// `rules`, a workspace, and both fakes. The root and the fakes are removed afterward.
// `responses` may be a function of the paths, for a gateway answer that needs them.
async function withFixture(
  options: {
    rules: Rule[];
    responses: GatewayResponse[] | ((paths: ScenarioPaths) => GatewayResponse[]);
    workspace?: "git" | "plain";
    /// The committed .gitignore of the git workspace.
    gitignore?: string;
    /// Replaces the sandbox config file's text, for a config fx cannot read.
    configText?: string;
    /// The script of the workspace recipe. fx builds a snapshot from it.
    workspaceRecipe?: string;
  },
  body: (fixture: Fixture) => Promise<void>,
): Promise<void> {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const disk = join(root, "disk");
  let sandbox: FakeSandboxApi | undefined;
  let gateway: Gateway | undefined;
  try {
    mkdirSync(join(home, ".fx", "sandbox"), { recursive: true });
    mkdirSync(disk, { recursive: true });
    const repo = options.workspace === "plain" ? makePlainFolder(root) : makeRepo(root, options.gitignore);
    sandbox = startFakeSandboxApi({ token: SANDBOX_TOKEN, diskRoot: disk });
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ experimental: { sandbox_execution: true } }),
    );
    const config: Record<string, unknown> = {
      team: "team-test",
      project: "project-test",
      api_url: sandbox.url,
      remote_root: disk,
      rules: options.rules,
    };
    if (options.workspaceRecipe !== undefined) {
      mkdirSync(join(home, "recipes"), { recursive: true });
      const recipe = join(home, "recipes", "setup.sh");
      writeFileSync(recipe, options.workspaceRecipe);
      config.workspace = { recipe };
    }
    writeFileSync(
      join(home, ".fx", "sandbox", "config.json"),
      options.configText ?? JSON.stringify(config),
    );
    const responses = typeof options.responses === "function"
      ? options.responses({ repo, disk })
      : options.responses;
    gateway = startFakeGateway(responses);
    await body({ root, home, repo, disk, sandbox, gateway });
  } finally {
    gateway?.stop();
    sandbox?.stop();
    cleanupIsolatedTestHome(root);
  }
}

function fxEnv(fixture: Fixture): Record<string, string | undefined> {
  return {
    HOME: fixture.home,
    VERCEL_TOKEN: SANDBOX_TOKEN,
    VERCEL_OIDC_TOKEN: undefined,
    AI_GATEWAY_API_KEY: GATEWAY_KEY,
    FX_GATEWAY_BASE_URL: fixture.gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
  };
}

type AskJson = { output: string; exit_code: number };

// `save` keeps the session, which a tty command needs; the other tests skip it.
async function ask(fixture: Fixture, prompt: string, options: { save?: boolean } = {}): Promise<AskJson> {
  const saving = options.save ? [] : ["--no-save"];
  const result = await runFx(
    ["ask", "--json", ...saving, "--permission-mode", "full-access", prompt],
    { cwd: fixture.repo, env: fxEnv(fixture), timeoutMs: TIMEOUT },
  );
  if (result.code !== 0) {
    throw new Error(`fx exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  }
  return JSON.parse(result.stdout.trim()) as AskJson;
}

// The output fx sent back for one tool call, read from the gateway's second request.
function toolResultOutput(body: string, callId: string): unknown {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : [],
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) => part.type === "tool-result" && part.toolCallId === callId);
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return result.output;
}

// The text fx sent back for one tool call, such as a read_file result.
function toolResultText(body: string, callId: string): string {
  const output = toolResultOutput(body, callId) as { value?: unknown };
  return typeof output.value === "string" ? output.value : JSON.stringify(output);
}

// The shell tool's snapshot: fx sends it as JSON text inside the output.
type ShellSnapshot = {
  state?: string;
  exit_code?: number | null;
  output_delta?: string;
  session_id?: string;
};

// fx appends an <fx-context-update> block to a tool result when the runtime
// context changed, such as an edit to this repository. It follows the
// snapshot, so the snapshot is the text before it.
const CONTEXT_UPDATE = "<fx-context-update>";

function shellSnapshot(body: string, callId: string): ShellSnapshot {
  const output = toolResultOutput(body, callId) as { value?: unknown };
  if (typeof output.value !== "string") return output.value as ShellSnapshot;
  const text = output.value.split(CONTEXT_UPDATE)[0]!.trim();
  try {
    return JSON.parse(text) as ShellSnapshot;
  } catch {
    throw new Error(`the ${callId} result is not a shell snapshot: ${output.value}`);
  }
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

// Polls until `condition` holds. Only a broken run reaches the deadline, so the
// poll never decides the result of a passing run.
async function waitFor(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(25);
  }
}

// The owner tag isolated.ownerTag writes for a process: the host's first bytes,
// with each byte outside A-Z a-z 0-9 . _ - replaced by "-", then ":pid". The
// whole tag is at most 64 bytes, so the host is cut to the room left by the pid.
function ownerTagFor(host: string, pid: number): string {
  const pidText = String(pid);
  const room = 64 - 1 - pidText.length;
  const kept = Array.from(Buffer.from(host, "utf8").subarray(0, room), (byte) => {
    const char = String.fromCharCode(byte);
    return /[A-Za-z0-9._-]/.test(char) ? char : "-";
  });
  return `${kept.join("")}:${pidText}`;
}

function filesNamed(dir: string, name: string): string[] {
  if (!existsSync(dir)) return [];
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...filesNamed(path, name));
    else if (entry.name === name) found.push(path);
  }
  return found;
}

describe("sandbox execution end to end", () => {
  test(
    "a workspace rule runs the command in the sandbox and brings new files back",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: [
            fakeShellRun("sandbox_workspace_call", "cat a.txt && echo made > made.txt"),
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Read a.txt and write made.txt.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(2);

          const snapshot = shellSnapshot(fixture.gateway.requests[1]!.body, "sandbox_workspace_call");
          const delta = snapshot.output_delta ?? "";
          expect(delta).toContain("hello");
          // The note reaches the model once, after the command's own output.
          expect(delta).toContain("fx: Ran in the workspace sandbox");
          expect(countOccurrences(delta, "fx: Ran in the workspace sandbox")).toBe(1);
          expect(delta.indexOf("fx: Ran in the workspace sandbox")).toBeGreaterThan(delta.indexOf("hello"));

          // The command ran in the sandbox's copy of the repository, and
          // made.txt came back to this machine.
          const sandboxCwd = join(fixture.disk, fixture.repo);
          expect(fixture.sandbox.records.commands).toContainEqual(
            expect.objectContaining({ cwd: sandboxCwd, args: ["-lc", "cat a.txt && echo made > made.txt"] }),
          );
          expect(existsSync(join(sandboxCwd, "a.txt"))).toBe(true);
          expect(existsSync(join(sandboxCwd, "made.txt"))).toBe(true);
          expect(readFileSync(join(fixture.repo, "made.txt"), "utf8").trim()).toBe("made");

          expect(fixture.sandbox.records.creates[0]).toBeDefined();
          expect(fixture.sandbox.records.creates[0]!.tags).toMatchObject({ fx: "workspace" });
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a command with no rule runs on this machine",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: [fakeShellRun("local_call", "echo local > l.txt"), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          const json = await ask(fixture, "Write l.txt.");
          expect(json.exit_code).toBe(0);
          expect(readFileSync(join(fixture.repo, "l.txt"), "utf8").trim()).toBe("local");

          // No rule matched, so the sandbox API saw nothing at all.
          expect(fixture.sandbox.records.creates).toHaveLength(0);
          expect(fixture.sandbox.records.commands).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a sandbox that cannot start never runs the command here",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: [
            fakeShellRun("refused_call", "cat a.txt && touch marker.txt"),
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          fixture.sandbox.fail("create", 500);
          const json = await ask(fixture, "Read a.txt and touch marker.txt.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(2);

          const snapshot = shellSnapshot(fixture.gateway.requests[1]!.body, "refused_call");
          const delta = snapshot.output_delta ?? "";
          expect(delta).toContain("fx: This command did not run.");
          expect(countOccurrences(delta, "fx: This command did not run.")).toBe(1);

          // The command reached no machine: not this one, and not the sandbox.
          expect(existsSync(join(fixture.repo, "marker.txt"))).toBe(false);
          expect(filesNamed(fixture.disk, "marker.txt")).toEqual([]);
          expect(fixture.sandbox.records.commands).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "an edit on this machine reaches the sandbox before the next command",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: ({ repo }) => [
            fakeShellRun("first_call", "cat a.txt"),
            () => {
              // The user edits a.txt after the first command and before the second.
              writeFileSync(join(repo, "a.txt"), "edited");
              return fakeShellRun("second_call", "cat a.txt");
            },
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Read a.txt, change it, and read it again.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(3);

          const first = shellSnapshot(fixture.gateway.requests[1]!.body, "first_call").output_delta ?? "";
          expect(first).toContain("hello");

          const second = shellSnapshot(fixture.gateway.requests[2]!.body, "second_call").output_delta ?? "";
          expect(second).toContain("edited");
          expect(second).not.toContain("hello");
          expect(readFileSync(join(fixture.disk, fixture.repo, "a.txt"), "utf8")).toBe("edited");
        },
      );
    },
    TIMEOUT,
  );

  test(
    "the sandbox never overwrites a file changed here during the command",
    async () => {
      await withFixture(
        {
          rules: [{ command: "sh *", placement: "workspace" }],
          responses: ({ disk }) => {
            // The command waits for the release file, which the test writes only
            // after it has changed a.txt here. Nothing depends on the clock.
            const release = join(disk, "release");
            return [
              fakeShellRun("overwrite_call", `sh -c 'while [ ! -e ${release} ]; do sleep 0.05; done; echo sandbox > a.txt'`),
              fakeGatewayFinalText("Done."),
            ];
          },
        },
        async (fixture) => {
          const release = join(fixture.disk, "release");
          const pending = ask(fixture, "Overwrite a.txt from the sandbox.");
          try {
            await waitFor(
              () => fixture.sandbox.records.commands.some((command) => command.args.some((arg) => arg.includes(release))),
              "the user command to reach the sandbox",
            );
            writeFileSync(join(fixture.repo, "a.txt"), "mine");
            writeFileSync(release, "go");
          } catch (error) {
            // Let the sandbox command end, so fx can finish, before the error propagates.
            writeFileSync(release, "go");
            await pending.catch(() => undefined);
            throw error;
          }
          const json = await pending;
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(2);

          const delta = shellSnapshot(fixture.gateway.requests[1]!.body, "overwrite_call").output_delta ?? "";
          expect(delta).toContain("fx: Kept this machine's version");
          expect(readFileSync(join(fixture.repo, "a.txt"), "utf8")).toBe("mine");
        },
      );
    },
    TIMEOUT,
  );

  test(
    "an isolated rule runs in a fresh sandbox with no keys and no network",
    async () => {
      await withFixture(
        {
          workspace: "plain",
          rules: [{ command: "cp *", placement: "isolated" }],
          responses: [
            fakeShellRun("isolated_call", "cp in.txt out.txt && env > env.txt"),
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Copy in.txt and record the environment.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(2);

          const delta = shellSnapshot(fixture.gateway.requests[1]!.body, "isolated_call").output_delta ?? "";
          expect(delta).toContain("fx: Ran in a new isolated sandbox");
          expect(delta).toContain("network none");

          // The run folder the note names holds the outputs and nothing else from the workspace.
          const folder = /New and changed files are in (\S+): /.exec(delta)?.[1];
          expect(folder).toBeDefined();
          expect(existsSync(folder!)).toBe(true);
          expect(readFileSync(join(folder!, "out.txt"), "utf8")).toBe("data");
          const env = readFileSync(join(folder!, "env.txt"), "utf8");
          expect(env).toContain("PATH=");
          expect(env).not.toContain("AI_GATEWAY_API_KEY");
          expect(env).not.toContain("VERCEL_TOKEN");

          expect(existsSync(join(fixture.repo, "out.txt"))).toBe(false);
          expect(existsSync(join(fixture.repo, "env.txt"))).toBe(false);

          const create = fixture.sandbox.records.creates.find(
            (body) => (body.tags as Record<string, string> | undefined)?.fx === "isolated",
          );
          expect(create).toBeDefined();
          expect(create!.networkPolicy).toEqual({ mode: "deny-all" });
          expect(create).not.toHaveProperty("env");
          expect(fixture.sandbox.records.deletes).toContain(create!.name as string);
          expect(fixture.sandbox.sandboxes().filter((sandbox) => sandbox.name.startsWith("fx-iso-"))).toEqual([]);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "read_file reads a file that only the workspace sandbox has",
    async () => {
      await withFixture(
        {
          rules: [{ command: "sh *", placement: "workspace" }],
          gitignore: "out/\n",
          responses: [
            fakeShellRun("build_call", "sh -c 'mkdir -p out && echo built > out/log.txt'"),
            fakeGatewayToolCall("read_call", "read_file", { path: "out/log.txt" }),
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Build, then read out/log.txt.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(3);

          const read = toolResultText(fixture.gateway.requests[2]!.body, "read_call");
          // The note comes first, then the file's own lines.
          expect(read.startsWith("fx: This file exists only in the workspace sandbox, so fx read the sandbox's copy.")).toBe(true);
          expect(read).toContain("built");

          // The file exists in the sandbox's copy, and the ignored output never came back.
          expect(existsSync(join(fixture.disk, fixture.repo, "out", "log.txt"))).toBe(true);
          expect(existsSync(join(fixture.repo, "out", "log.txt"))).toBe(false);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a broken sandbox config refuses every shell command",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          configText: "{",
          responses: [
            fakeShellRun("broken_read", "cat a.txt"),
            fakeShellRun("broken_write", "echo hi > hi.txt"),
            fakeGatewayFinalText("Done."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Read a.txt, then write hi.txt.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(3);

          // The config cannot be read, so no rule can match, and each command is refused.
          const read = shellSnapshot(fixture.gateway.requests[1]!.body, "broken_read").output_delta ?? "";
          const write = shellSnapshot(fixture.gateway.requests[2]!.body, "broken_write").output_delta ?? "";
          for (const delta of [read, write]) {
            expect(delta).toContain("fx: This command did not run.");
            expect(delta).toContain("config.json cannot be used");
          }
          expect(existsSync(join(fixture.repo, "hi.txt"))).toBe(false);

          // The fake saw no call at all: no sandbox was made and no command ran there.
          expect(fixture.sandbox.records.creates).toHaveLength(0);
          expect(fixture.sandbox.records.commands).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "stopping a background sandbox command kills it in the sandbox",
    async () => {
      const started = Date.now();
      await withFixture(
        {
          rules: [{ command: "sleep *", placement: "workspace" }],
          responses: [
            fakeShellRun("run_1", "sleep 30", { yield_time_ms: 500 }),
            (body) => {
              const sessionId = shellSnapshot(body, "run_1").session_id;
              if (!sessionId) throw new Error("the background result has no session_id");
              return fakeGatewayToolCall("stop_1", "shell", {
                request: { action: "stop", session_id: sessionId },
              });
            },
            fakeGatewayFinalText("Stopped."),
          ],
        },
        async (fixture) => {
          const json = await ask(fixture, "Start a long command, then stop it.");
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(3);

          // The first answer came back while the command still ran.
          const running = shellSnapshot(fixture.gateway.requests[1]!.body, "run_1");
          expect(running.state).toBe("running");
          expect(running.session_id).toBeTruthy();

          // The stop reached the sandbox, which killed the command.
          expect(fixture.sandbox.records.kills.length).toBeGreaterThan(0);
          const stopped = shellSnapshot(fixture.gateway.requests[2]!.body, "stop_1");
          expect(stopped.state).toBe("stopped");

          // A 30 second command that was stopped finishes well inside this bound.
          expect(Date.now() - started).toBeLessThan(20_000);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "the startup sweep removes an isolated sandbox that a dead fx left",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: [fakeShellRun("local_call", "echo local > l.txt"), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          const deadName = "fx-iso-00000001deadbeef";
          const otherName = "fx-iso-00000002cafebabe";
          // This host's dead process: the sweep removes it. Another host's sandbox stays.
          fixture.sandbox.addSandbox(deadName, { fx: "isolated", owner: ownerTagFor(hostname(), 999999) });
          fixture.sandbox.addSandbox(otherName, { fx: "isolated", owner: "other-host:999999" });

          const json = await ask(fixture, "Write l.txt.");
          expect(json.exit_code).toBe(0);
          expect(readFileSync(join(fixture.repo, "l.txt"), "utf8").trim()).toBe("local");

          expect(fixture.sandbox.records.deletes).toContain(deadName);
          expect(fixture.sandbox.records.deletes).not.toContain(otherName);
          const names = fixture.sandbox.sandboxes().map((sandbox) => sandbox.name);
          expect(names).not.toContain(deadName);
          expect(names).toContain(otherName);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a workspace recipe builds a snapshot once and the sandbox starts from it",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          workspaceRecipe: "echo recipe-ran > recipe-ran.txt\n",
          responses: [
            fakeShellRun("recipe_read_1", "cat a.txt"),
            fakeGatewayFinalText("First done."),
            fakeShellRun("recipe_read_2", "cat a.txt"),
            fakeGatewayFinalText("Second done."),
          ],
        },
        async (fixture) => {
          const builders = () =>
            fixture.sandbox.records.creates.filter(
              (body) => (body.tags as Record<string, string> | undefined)?.fx === "build",
            );

          const first = await ask(fixture, "Read a.txt.");
          expect(first.exit_code).toBe(0);
          expect(builders()).toHaveLength(1);
          expect(fixture.sandbox.records.snapshots).toHaveLength(1);
          const snapshotId = fixture.sandbox.records.snapshots[0]!;
          // The workspace sandbox starts from the snapshot, not from an empty image.
          const workspace = fixture.sandbox.records.creates.find(
            (body) => (body.tags as Record<string, string> | undefined)?.fx === "workspace",
          );
          expect(workspace?.source).toEqual({ type: "snapshot", snapshotId });

          // The saved snapshot still exists, so the second run builds nothing.
          const second = await ask(fixture, "Read a.txt again.");
          expect(second.exit_code).toBe(0);
          expect(builders()).toHaveLength(1);
          expect(fixture.sandbox.records.snapshots).toHaveLength(1);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a tty command placed in a sandbox is refused",
    async () => {
      await withFixture(
        {
          rules: [{ command: "cat *", placement: "workspace" }],
          responses: [fakeShellRun("tty_call", "cat a.txt", { tty: true }), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          const json = await ask(fixture, "Read a.txt in a terminal.", { save: true });
          expect(json.exit_code).toBe(0);
          expect(fixture.gateway.requests).toHaveLength(2);

          const output = JSON.stringify(toolResultOutput(fixture.gateway.requests[1]!.body, "tty_call"));
          expect(output).toContain("tty=true commands run only on this machine");
          expect(
            fixture.sandbox.records.commands.some((command) => command.args.some((arg) => arg.includes("cat a.txt"))),
          ).toBe(false);
        },
      );
    },
    TIMEOUT,
  );
});
