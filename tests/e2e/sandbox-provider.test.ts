import { describe, expect, test } from "bun:test";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";

// fx runs the built binary against a fake model gateway. A rule in the
// private sandbox config places a shell call; fx runs the default provider,
// src/core/sandbox/providers/vercel.sh, which drives the fake sandbox CLI in
// fixtures/fake-sandbox-cli.ts. The fake runs each sandbox on this machine and
// logs every step, so a test can see where a command ran.
// tests/tla/drivers/sandbox/driver.ts walks the same code along
// tests/tla/sandbox/SandboxProvider.tla.
const TIMEOUT = 120_000;
const FAKE_CLI = join(import.meta.dir, "fixtures", "fake-sandbox-cli.ts");

type Gateway = ReturnType<typeof startFakeGateway>;
type GatewayResponse = Parameters<typeof startFakeGateway>[0][number];
type Fixture = { root: string; home: string; repo: string; fake: string; gateway: Gateway };

function git(cwd: string, args: string[]) {
  execFileSync("git", ["-c", "commit.gpgsign=false", ...args], {
    cwd,
    env: { ...process.env, GIT_AUTHOR_NAME: "fx test", GIT_AUTHOR_EMAIL: "test@example.com", GIT_COMMITTER_NAME: "fx test", GIT_COMMITTER_EMAIL: "test@example.com" },
    stdio: "ignore",
  });
}

// The fake's daemon runs the detached commands outside fx's process tree, as a
// real sandbox does.
async function startFakeDaemon(fakeHome: string): Promise<ChildProcess> {
  const daemon = spawn(FAKE_CLI, ["__daemon"], { env: { ...process.env, FAKE_SANDBOX_HOME: fakeHome }, stdio: "ignore" });
  const deadline = Date.now() + 10_000;
  while (!existsSync(join(fakeHome, "daemon.pid"))) {
    if (Date.now() > deadline) throw new Error("the fake sandbox daemon did not start");
    await Bun.sleep(10);
  }
  return daemon;
}

async function withFixture(
  options: {
    rules?: Array<{ command: string; placement: string }>;
    config?: Record<string, unknown>;
    configText?: string;
    responses: GatewayResponse[] | ((fixture: Omit<Fixture, "gateway">) => GatewayResponse[]);
  },
  body: (fixture: Fixture) => Promise<void>,
) {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const repo = join(root, "repo");
  const fake = join(root, "fake");
  let gateway: Gateway | undefined;
  let daemon: ChildProcess | undefined;
  try {
    mkdirSync(join(home, ".fx", "sandbox"), { recursive: true });
    mkdirSync(repo);
    mkdirSync(fake);
    writeFileSync(join(repo, "a.txt"), "hello\n");
    git(repo, ["init", "-q"]);
    git(repo, ["add", "a.txt"]);
    git(repo, ["commit", "-q", "-m", "initial"]);
    chmodSync(FAKE_CLI, 0o755);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { sandbox_execution: true } }));
    const config = {
      provider_args: ["--cli", FAKE_CLI, "--remote-base", join(fake, "fs"), "--command-timeout", "60s"],
      rules: options.rules ?? [],
      ...options.config,
    };
    writeFileSync(join(home, ".fx", "sandbox", "config.json"), options.configText ?? JSON.stringify(config));
    const responses = typeof options.responses === "function" ? options.responses({ root, home, repo, fake }) : options.responses;
    gateway = startFakeGateway(responses);
    daemon = await startFakeDaemon(fake);
    await body({ root, home, repo, fake, gateway });
  } finally {
    gateway?.stop();
    daemon?.kill("SIGKILL");
    killFakeCommands(fake);
    cleanupIsolatedTestHome(root);
  }
}

// Stops the fake's commands that this test started, by their process groups.
function killFakeCommands(fake: string) {
  const dir = join(fake, "commands");
  if (!existsSync(dir)) return;
  for (const id of readdirSync(dir)) {
    if (existsSync(join(dir, id, "exit")) || !existsSync(join(dir, id, "pid"))) continue;
    try { process.kill(-Number(readFileSync(join(dir, id, "pid"), "utf8")), "SIGKILL"); } catch {}
  }
}

// The fake's log, without the `ls` of the sweep fx runs at every start.
function events(fixture: Fixture): Array<Record<string, unknown>> {
  const file = join(fixture.fake, "events.jsonl");
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)).filter((e) => e.ev !== "ls");
}

async function ask(fixture: Fixture, options: { save?: boolean } = {}) {
  const result = await runFx(
    ["ask", "--json", ...(options.save ? [] : ["--no-save"]), "--permission-mode", "full-access", "Run the command."],
    {
      cwd: fixture.repo,
      timeoutMs: TIMEOUT,
      env: {
        HOME: fixture.home,
        VERCEL_TOKEN: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        AI_GATEWAY_API_KEY: "sandbox-provider-fake-key",
        FX_GATEWAY_BASE_URL: fixture.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: fixture.gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FAKE_SANDBOX_HOME: fixture.fake,
        SECRET: "s3cret",
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
    "a workspace rule runs the command through the provider and brings new files back",
    async () => {
      const command = "cat a.txt; echo made > made.txt";
      await withFixture(
        { rules: [{ command, placement: "workspace" }], responses: [fakeShellRun("run_1", command), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("hello");
          expect(text).toContain("fx: ran in the workspace sandbox fx-ws-");
          expect(text).toContain("fx: brought back: made.txt");
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
        { rules: [{ command: "make *", placement: "workspace" }], responses: [fakeShellRun("run_1", "echo here > here.txt"), fakeGatewayFinalText("Done.")] },
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
      const command = "echo \"secret=[${SECRET:-}]\"";
      await withFixture(
        {
          rules: [{ command, placement: "isolated" }],
          config: { env: ["SECRET"] },
          responses: [fakeShellRun("run_1", command), fakeGatewayFinalText("Done.")],
        },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("secret=[]");
          expect(text).toContain("fx: ran in a new isolated sandbox");
          const log = events(fixture);
          const created = log.find((e) => e.ev === "create")!;
          expect(created.network).toBe("deny-all");
          expect(created.persistent).toBe(false);
          expect(log.find((e) => e.ev === "start")!.env).toEqual([]);
          expect(log.map((e) => e.ev)).toContain("rm");
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
        { rules: [{ command, placement: "workspace" }], responses: [fakeShellRun("run_1", command, { tty: true }), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture, { save: true });
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("fx did not run this command: a tty=true command cannot run in a sandbox");
          expect(events(fixture)).toHaveLength(0);
        },
      );
    },
    TIMEOUT,
  );

  test(
    "an invalid sandbox config refuses every shell command",
    async () => {
      await withFixture(
        { configText: "{\"rules\": [{\"command\": \"x\", \"placement\": \"sandbox\"}]}", responses: [fakeShellRun("run_1", "echo here > here.txt"), fakeGatewayFinalText("Done.")] },
        async (fixture) => {
          await ask(fixture);
          const text = toolTexts(fixture.gateway);
          expect(text).toContain("fx did not run this command:");
          expect(text).toContain("rules[0].placement");
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
          rules: [{ command, placement: "workspace" }],
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
          rules: [{ command: "sleep *", placement: "workspace" }],
          responses: [
            fakeShellRun("run_1", "sleep 30", { yield_time_ms: 500 }),
            (body) => fakeGatewayToolCall("stop_1", "shell", { request: { action: "stop", session_id: sessionId(body) } }),
            fakeGatewayFinalText("Stopped."),
          ],
        },
        async (fixture) => {
          const started = Date.now();
          await ask(fixture);
          const log = events(fixture).map((e) => e.ev);
          expect(log).toContain("killsent");
          expect(log).toContain("killed");
          // A 30 second command that was stopped ends well inside this bound.
          expect(Date.now() - started).toBeLessThan(20_000);
        },
      );
    },
    TIMEOUT,
  );
});
