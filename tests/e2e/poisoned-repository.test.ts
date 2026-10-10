import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
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
import { runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// A repository's own git config can name programs: fsmonitor, hooks, clean
// and smudge filters, diff drivers and the pager. Opening a repository in fx
// must never run them. A control first proves the fixture's programs run
// under plain git; every fx path below must then leave the sentinel log
// empty while still answering from the repository's real contents.

const TIMEOUT = 60_000;
const MODEL = "openai/gpt-5";
const tmuxTest = test.skipIf(!tmuxAvailable());

type Fixture = {
  base: string;
  home: string;
  workspace: string;
  log: string;
};

type Gateway = ReturnType<typeof startFakeGateway>;

const fixtures: Fixture[] = [];
const gateways: Gateway[] = [];
let session: TmuxSession | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const fixture of fixtures.splice(0)) {
    rmSync(fixture.base, { recursive: true, force: true });
  }
});

function git(fixture: Fixture, args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], {
    cwd: fixture.workspace,
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      HOME: fixture.home,
      GIT_CONFIG_NOSYSTEM: "1",
      LC_ALL: "C",
    },
  });
  if (result.exitCode !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString()}`);
  }
  return result.stdout.toString();
}

function sentinelRuns(fixture: Fixture): string[] {
  if (!existsSync(fixture.log)) return [];
  return readFileSync(fixture.log, "utf8").split("\n").filter(Boolean);
}

function poisonedRepository(): Fixture {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "fx-poisoned-repo-")));
  const fixture: Fixture = {
    base,
    home: join(base, "home"),
    workspace: join(base, "workspace"),
    log: join(base, "sentinel.log"),
  };
  fixtures.push(fixture);
  mkdirSync(join(fixture.home, ".fx"), { recursive: true });
  mkdirSync(join(fixture.workspace, "notes"), { recursive: true });
  writeFileSync(
    join(fixture.home, ".fx", "settings.json"),
    JSON.stringify({ auto_upgrade: false }),
  );
  const sentinel = join(base, "sentinel.sh");
  writeFileSync(sentinel, `#!/bin/sh\necho "ran $0 $*" >> '${fixture.log}'\ncat\n`);
  chmodSync(sentinel, 0o755);
  const hooks = join(base, "hooks");
  mkdirSync(hooks);
  for (const hook of ["post-index-change", "pre-commit", "post-checkout"]) {
    writeFileSync(join(hooks, hook), readFileSync(sentinel));
    chmodSync(join(hooks, hook), 0o755);
  }

  git(fixture, ["init", "-q", "--template=", "-b", "main"]);
  writeFileSync(join(fixture.workspace, "alpha-tracked.txt"), "needle tracked one\n");
  writeFileSync(join(fixture.workspace, ".gitattributes"), "*.txt filter=evil diff=evil\n");
  git(fixture, ["add", "-A"]);
  git(fixture, ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "fixture commit"]);
  for (const [key, value] of [
    ["core.fsmonitor", sentinel],
    ["core.hooksPath", hooks],
    ["core.pager", sentinel],
    ["filter.evil.clean", sentinel],
    ["filter.evil.smudge", sentinel],
    ["diff.external", sentinel],
    ["diff.evil.textconv", sentinel],
  ]) git(fixture, ["config", key!, value!]);
  writeFileSync(join(fixture.workspace, "alpha-tracked.txt"), "needle tracked two\n");
  writeFileSync(join(fixture.workspace, "notes", "alpha-untracked.txt"), "needle untracked\n");
  writeFileSync(fixture.log, "");
  return fixture;
}

function fxEnv(fixture: Fixture, gateway: Gateway): Record<string, string> {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "fake-poisoned-repo-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_SOUND: "0",
    NO_COLOR: "1",
  };
}

function toolResult(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const part = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((item) => item.type === "tool-result" && item.toolCallId === toolCallId);
  if (!part) throw new Error(`No tool result for ${toolCallId}`);
  const output = part.output as { value?: unknown };
  return typeof output.value === "string" ? output.value : JSON.stringify(output.value);
}

describe("poisoned repository", () => {
  test("plain git runs the fixture's programs", () => {
    const fixture = poisonedRepository();
    git(fixture, ["status", "--short"]);
    expect(sentinelRuns(fixture).length).toBeGreaterThan(0);
  });

  tmuxTest(
    "interactive startup and @ completion run none of the repository's programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway([], { classifierResponses: [] });
      gateways.push(gateway);
      const stderrPath = join(fixture.base, "stderr.log");
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: fxEnv(fixture, gateway),
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendLiteral("@alpha");
      await session.waitForPane(
        (pane) => pane.includes("alpha-tracked.txt") && pane.includes("alpha-untracked.txt"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;

      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.requests).toHaveLength(0);
    },
    TIMEOUT,
  );

  test(
    "glob, grep and auto-run git status answer without running the repository's programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway([
        fakeGatewayToolCall("glob", "glob_files", { pattern: "**/alpha-*.txt" }),
        fakeGatewayToolCall("grep", "grep_files", { pattern: "needle" }),
        fakeGatewayToolCall("status", "shell", {
          request: { action: "run", command: "git status --short", profile: "clean", yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      // `fx ask` reports each tool's activity on stderr.
      expect(result.stderr).toContain("Running git status --short");
      expect(result.stderr).not.toMatch(/panic|error/i);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(0);

      const bodies = gateway.requests.map((request: { body: string }) => request.body);
      const glob = toolResult(bodies[1]!, "glob");
      expect(glob).toContain("alpha-tracked.txt");
      expect(glob).toContain("notes/alpha-untracked.txt");
      const grep = toolResult(bodies[2]!, "grep");
      expect(grep).toContain("needle tracked two");
      expect(grep).toContain("needle untracked");
      const status = toolResult(bodies[3]!, "status");
      expect(status).toContain("M alpha-tracked.txt");
      expect(status).toContain("?? notes/");
    },
    TIMEOUT,
  );

  test(
    "fx pr snapshots the repository without running its programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway(
        [fakeGatewayFinalText("Draft title\n\n## Summary\n\n- Draft")],
        { classifierResponses: [] },
      );
      gateways.push(gateway);

      const result = await runFx(["pr"], {
        cwd: fixture.workspace,
        env: fxEnv(fixture, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(result.code, result.stderr).toBe(0);
      expect(sentinelRuns(fixture)).toEqual([]);
      const prompt = gateway.requests[0]?.body ?? "";
      for (const expected of ["Branch: main", "M alpha-tracked.txt", "fixture commit", "alpha-tracked.txt |"]) {
        expect(prompt).toContain(expected);
      }
    },
    TIMEOUT,
  );
});
