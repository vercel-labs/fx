import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";
import { expectRemoteLoginNeverSent, type RemoteSetupFixture, startRemoteSetupFixture } from "./remote-setup-fixture";

// fx runs the built binary against a fake model gateway. A rule in the private sandbox
// config places a shell call, and fx starts the built-in runner (`fx __fx_runner__`),
// which talks to the fake Vercel API this file starts. A third-party provider gets the
// L2 argv instead, and only its own script runs. tests/tla/drivers/sandbox/driver.ts
// walks the provider path along tests/tla/sandbox/SandboxProviderTrace.tla.
const TIMEOUT = 120_000;

// The built-in runner's login and setup go to one fake Vercel API for this file.
// Every test root lives under one base folder, which the fake maps to its own folder
// (macRoots), so a command's mkdir and the push agree on one path.
const macBase = realpathSync(mkdtempSync(join(tmpdir(), "fx-sandbox-provider-")));
let remoteSetup: RemoteSetupFixture;
beforeAll(() => {
  remoteSetup = startRemoteSetupFixture({ macRoots: [macBase] });
});
afterAll(() => remoteSetup?.stop());

type Gateway = ReturnType<typeof startFakeGateway>;
type GatewayResponse = Parameters<typeof startFakeGateway>[0][number];
type Fixture = { root: string; home: string; repo: string; gateway: Gateway; logStart: number };

function git(cwd: string, args: string[]) {
  execFileSync("git", ["-c", "commit.gpgsign=false", ...args], {
    cwd,
    env: { ...process.env, GIT_AUTHOR_NAME: "fx test", GIT_AUTHOR_EMAIL: "test@example.com", GIT_COMMITTER_NAME: "fx test", GIT_COMMITTER_EMAIL: "test@example.com" },
    stdio: "ignore",
  });
}

async function withFixture(
  options: {
    rules?: Array<{ command: string; runner: string }>;
    config?: Record<string, unknown>;
    configText?: string;
    responses: GatewayResponse[] | ((fixture: Omit<Fixture, "gateway" | "logStart">) => GatewayResponse[]);
  },
  body: (fixture: Fixture) => Promise<void>,
) {
  const root = realpathSync(mkdtempSync(join(macBase, "case-")));
  const home = join(root, "home");
  const repo = join(root, "repo");
  let gateway: Gateway | undefined;
  try {
    mkdirSync(join(home, ".fx", "sandbox"), { recursive: true });
    mkdirSync(repo);
    writeFileSync(join(repo, "a.txt"), "hello\n");
    git(repo, ["init", "-q"]);
    git(repo, ["add", "a.txt"]);
    git(repo, ["commit", "-q", "-m", "initial"]);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { sandbox_execution: true } }));
    const config = {
      rules: options.rules ?? [],
      remote: remoteSetup.remote,
      ...options.config,
    };
    writeFileSync(join(home, ".fx", "sandbox", "config.json"), options.configText ?? JSON.stringify(config));
    const responses = typeof options.responses === "function" ? options.responses({ root, home, repo }) : options.responses;
    gateway = startFakeGateway(responses);
    await body({ root, home, repo, gateway, logStart: remoteSetup.api.log.length });
  } finally {
    gateway?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

// The fake Vercel API's requests made since this fixture started. The API is shared by
// the file, so a fixture reads only its own entries.
function apiSince(fixture: Fixture) {
  return remoteSetup.api.log.slice(fixture.logStart);
}

// This fixture's exec commands, as the fake saw them: a start for each, and an exit
// once it ended.
function events(fixture: Fixture): Array<Record<string, unknown>> {
  const ids = new Set(apiSince(fixture).filter((entry) => entry.route === "cmd" && entry.kind === "exec").map((entry) => entry.commandId));
  const out: Array<Record<string, unknown>> = [];
  for (const command of remoteSetup.api.commands()) {
    if (!ids.has(command.id)) continue;
    out.push({ ev: "start", id: command.id, argv: command.args });
    if (command.status !== "running") out.push({ ev: "exit", id: command.id, code: command.exitCode });
  }
  return out;
}

// The requests that mean a command reached the sandbox or ran in it: a sandbox create,
// or an exec command.
function execRequests(fixture: Fixture) {
  return apiSince(fixture).filter((entry) => entry.route === "createSandbox" || (entry.route === "cmd" && entry.kind === "exec"));
}

async function ask(fixture: Fixture, options: { save?: boolean; env?: Record<string, string> } = {}) {
  const result = await runFx(
    ["ask", "--json", ...(options.save ? [] : ["--no-save"]), "--permission-mode", "full-access", "Run the command."],
    {
      cwd: fixture.repo,
      timeoutMs: TIMEOUT,
      env: {
        HOME: fixture.home,
        VERCEL_OIDC_TOKEN: undefined,
        ...remoteSetup.env,
        AI_GATEWAY_API_KEY: "sandbox-provider-fake-key",
        FX_GATEWAY_BASE_URL: fixture.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        SECRET: "s3cret",
        ...options.env,
      },
    },
  );
  if (result.code !== 0) throw new Error(`fx exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  return result;
}

// Every tool result text fx sent back, in order.
function toolTexts(gateway: Gateway): string {
  const texts: string[] = [];
  for (const request of gateway.requests.slice(1)) {
    const body = JSON.parse(request.body) as { prompt?: Array<{ content: unknown }> };
    for (const message of body.prompt ?? []) {
      if (!Array.isArray(message.content)) continue;
      for (const part of message.content as Array<Record<string, unknown>>) {
        if (part.type !== "tool-result") continue;
        const output = part.output as { value?: unknown };
        texts.push(typeof output?.value === "string" ? output.value : JSON.stringify(output));
      }
    }
  }
  return texts.join("\n");
}

function sessionId(body: string): string {
  const match = /\\?"session_id\\?"\s*:\s*\\?"([^"\\]+)/.exec(body);
  if (!match) throw new Error("the background result has no session_id");
  return match[1]!;
}

describe("sandbox provider end to end", () => {
  test(
    "a remote rule runs the command through the provider and brings new files back",
    async () => {
      const command = "cat a.txt; echo made > made.txt";
      await withFixture(
        { rules: [{ command, runner: "remote" }], responses: [fakeShellRun("run_1", command), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("hello");
          expect(text).toContain("fx: ran on remote vercel:");
          expect(text).toContain("1 file back");
          expect(readFileSync(join(fixture.repo, "made.txt"), "utf8")).toBe("made\n");
          expect(events(fixture).map((e) => e.ev)).toContain("start");
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a command with no rule runs on this machine",
    async () => {
      await withFixture(
        { rules: [{ command: "make *", runner: "remote" }], responses: [fakeShellRun("run_1", "echo here > here.txt"), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          expect(readFileSync(join(fixture.repo, "here.txt"), "utf8")).toBe("here\n");
          expect(events(fixture)).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "an isolated rule gets no configured env and no network, and its sandbox is removed",
    async () => {
      const command = 'echo "secret=[${SECRET:-}]"';
      await withFixture(
        {
          rules: [{ command, runner: "isolated" }],
          config: { env: ["SECRET"] },
          responses: [fakeShellRun("run_1", command), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("secret=[]");
          // N14: an isolated run's note names the runs folder, not the repository.
          expect(text).toContain("fx: ran isolated on vercel:fx-test-team/fx-test-project; ");
          expect(text).toMatch(/ files? saved in \S+\/runs\/\S+/);
          const created = apiSince(fixture).find((entry) => entry.route === "createSandbox")!;
          const createBody = created.body as { persistent?: unknown; networkPolicy?: { mode?: unknown } };
          expect(createBody.networkPolicy?.mode).toBe("deny-all");
          expect(createBody.persistent).toBe(false);
          const exec = apiSince(fixture).find((entry) => entry.route === "cmd" && entry.kind === "exec")!;
          const execBody = exec.body as { env?: unknown };
          expect(execBody.env ?? {}).toEqual({});
          expect(JSON.stringify(execBody.env ?? {})).not.toContain("SECRET");
          expect(apiSince(fixture).some((entry) => entry.route === "deleteSandbox")).toBe(true);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a placed tty command is refused before anything starts",
    async () => {
      const command = "echo never";
      await withFixture(
        { rules: [{ command, runner: "remote" }], responses: [fakeShellRun("run_1", command, { tty: true }), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture, { save: true });
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("fx did not run this command: a tty=true command cannot run in a sandbox");
          expect(execRequests(fixture)).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "an invalid sandbox config refuses every shell command",
    async () => {
      await withFixture(
        { configText: '{"rules": [{"command": "x", "runner": "sandbox"}]}', responses: [fakeShellRun("run_1", "echo here > here.txt"), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("fx did not run this command:");
          expect(text).toContain("rules[0].runner");
          expect(existsSync(join(fixture.repo, "here.txt"))).toBe(false);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "a placed command whose provider cannot be used is refused and never runs here",
    async () => {
      const command = "echo here > here.txt";
      await withFixture(
        {
          rules: [{ command, runner: "remote" }],
          config: { provider: ["/nonexistent/fx-sandbox-provider"] },
          responses: [fakeShellRun("run_1", command), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("fx did not run this command: the sandbox provider cannot be used");
          expect(existsSync(join(fixture.repo, "here.txt"))).toBe(false);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "stopping a placed background command kills it in the sandbox",
    async () => {
      await withFixture(
        {
          rules: [{ command: "sleep *", runner: "remote" }],
          responses: [
            fakeShellRun("run_1", "sleep 30", { yield_time_ms: 500 }),
            (body) => fakeGatewayToolCall("stop_1", "shell", { request: { action: "stop", session_id: sessionId(body) } }),
            fakeGatewayFinalText("Stopped."),
          ],
        },
        async (fixture) => {
          const started = Date.now();
          await ask(fixture);
          expect(apiSince(fixture).some((entry) => entry.route === "kill")).toBe(true);
          const ids = new Set(apiSince(fixture).filter((entry) => entry.route === "cmd" && entry.kind === "exec").map((entry) => entry.commandId));
          expect(remoteSetup.api.commands().filter((command) => ids.has(command.id)).map((command) => command.status)).toContain("killed");
          // A 30 second command that was stopped ends well inside this bound.
          expect(Date.now() - started).toBeLessThan(20_000);
        },
      );
      // Once per file: the fake saw only the test token, never the login.
      expectRemoteLoginNeverSent(remoteSetup.api);
    },
    TIMEOUT,
  );

  test(
    "a placed remote command reaches the fake through the built-in runner, and no vercel script is written",
    async () => {
      await withFixture(
        { rules: [{ command: "echo hi", runner: "remote" }], responses: [fakeShellRun("run_1", "echo hi"), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          expect(toolTexts(fixture.gateway)).toContain("hi");
          expect(events(fixture).length).toBeGreaterThan(0);
          const sandboxFolder = join(fixture.home, ".fx", "sandbox");
          expect(existsSync(join(sandboxFolder, "providers"))).toBe(false);
          expect(readdirSync(sandboxFolder).filter((name) => /^vercel-.*\.sh$/.test(name))).toEqual([]);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "two repositories get two keyed sandbox names (spec L5)",
    async () => {
      const names: string[] = [];
      for (let index = 0; index < 2; index += 1) {
        await withFixture(
          { rules: [{ command: "echo hi", runner: "remote" }], responses: [fakeShellRun("run_1", "echo hi"), fakeGatewayFinalText("Done.")] },
          async (fixture) => {
            await ask(fixture);
            const created = apiSince(fixture).find((entry) => entry.route === "createSandbox")!;
            names.push((created.body as { name: string }).name);
          },
        );
      }
      for (const name of names) expect(name).toMatch(/^fx-[0-9a-f]{16}$/);
      expect(names[0]).not.toBe(names[1]);
    },
    TIMEOUT,
  );

  test(
    "fx startup sends no list request to the fake (no sweep, spec I1)",
    async () => {
      await withFixture({ responses: [fakeGatewayFinalText("Done.")] }, async (fixture) => {
        await ask(fixture);
        expect(apiSince(fixture).filter((entry) => entry.route === "listSandboxes")).toEqual([]);
      });
    },
    TIMEOUT,
  );

  test(
    "the runner starts without startup files: a BASH_ENV or ZDOTDIR trap never writes its marker",
    async () => {
      const trapDir = mkdtempSync(join(tmpdir(), "fx-trap-"));
      try {
        const marker = join(trapDir, "marker");
        const trap = join(trapDir, "trap.sh");
        writeFileSync(trap, `: > '${marker}'\n`);
        const zdot = join(trapDir, "zdot");
        mkdirSync(zdot);
        writeFileSync(join(zdot, ".zshenv"), `: > '${marker}'\n`);
        await withFixture(
          { rules: [{ command: "echo hi", runner: "remote" }], responses: [fakeShellRun("run_1", "echo hi"), fakeGatewayFinalText("Done.")] },
          async (fixture) => {
            await ask(fixture, { env: { BASH_ENV: trap, ZDOTDIR: zdot } });
            expect(toolTexts(fixture.gateway)).toContain("hi");
            expect(existsSync(marker)).toBe(false);
          },
        );
      } finally {
        rmSync(trapDir, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a third-party provider still gets the L2 argv: no contract, team, project, or token",
    async () => {
      const providerDir = mkdtempSync(join(tmpdir(), "fx-l2-"));
      try {
        const argvFile = join(providerDir, "argv.txt");
        const provider = join(providerDir, "provider.sh");
        writeFileSync(provider, `#!/bin/sh\nprintf '%s\\n' "$@" > '${argvFile}'\n`);
        chmodSync(provider, 0o755);
        const config = JSON.stringify({
          provider: [provider],
          rules: [{ command: "echo third", runner: "remote" }],
        });
        await withFixture(
          { configText: config, responses: [fakeShellRun("run_1", "echo third"), fakeGatewayFinalText("Done.")] },
          async (fixture) => {
            await ask(fixture);
            const words = readFileSync(argvFile, "utf8").split("\n").filter((line) => line.length > 0);
            expect(words.slice(0, 3)).toEqual(["run", "--mode", "remote"]);
            expect(words).toContain("--root");
            expect(words).toContain(fixture.repo);
            expect(words).toContain("--state");
            expect(words).not.toContain("--contract");
            expect(words).not.toContain("--team");
            expect(words).not.toContain("--token-sha256");
            expect(words.at(-2)).toBe("--");
            expect(words.at(-1)).toBe("echo third");
            expect(events(fixture)).toHaveLength(0);
          },
        );
      } finally {
        rmSync(providerDir, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
