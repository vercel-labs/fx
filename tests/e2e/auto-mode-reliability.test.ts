import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewaySse,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let activeSession: TmuxSession | null = null;

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(baseDir = tmpdir()): IsolatedRoot {
  const root = realpathSync(
    mkdtempSync(join(baseDir, "fx-auto-mode-reliability-e2e-")),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission: {} }),
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-auto-mode-reliability-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function commandCall(command: string, id: string) {
  return fakeGatewayToolCall(id, "terminal", { action: "exec", command });
}

function cleanCommandCall(command: string, id: string) {
  return fakeGatewayToolCall(id, "terminal", {
    action: "exec",
    command,
    profile: "clean",
  });
}

function toolResultText(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as Record<string, unknown>;
  expect(output.type).toBe("text");
  expect(typeof output.value).toBe("string");
  return output.value as string;
}

function installRecorder(root: IsolatedRoot, name: string, marker: string) {
  const bin = join(root.root, "bin");
  mkdirSync(bin, { recursive: true });
  const executable = join(bin, name);
  writeFileSync(
    executable,
    `#!/bin/sh\nprintf '%s:%s\\n' ${JSON.stringify(name)} "$*" >> ${JSON.stringify(marker)}\n`,
  );
  chmodSync(executable, 0o755);
  return bin;
}

function runGit(cwd: string, args: string[]) {
  const result = Bun.spawnSync(["/usr/bin/git", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  expect(
    result.exitCode,
    `git ${args.join(" ")} failed: ${result.stderr.toString()}`,
  ).toBe(0);
  return result.stdout.toString();
}

function startGateway(
  responses: Parameters<typeof startFakeGateway>[0],
  classifierResponses: NonNullable<
    Parameters<typeof startFakeGateway>[1]
  >["classifierResponses"] = [],
) {
  const gateway = startFakeGateway(responses, { classifierResponses });
  gateways.push(gateway);
  return gateway;
}

async function waitForEither(
  session: TmuxSession,
  expected: string[],
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let scrollback = "";
  while (Date.now() < deadline) {
    scrollback = await session.captureFullScrollback();
    if (expected.some((value) => scrollback.includes(value))) return scrollback;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${expected.map(JSON.stringify).join(" or ")}`);
}

describe("lean auto mode reliability", () => {
  test(
    "a configured safe command bypasses automatic review",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { pwd: "allow" } },
        }),
      );
      const gateway = startGateway(
        [commandCall("pwd", "direct_pwd"), fakeGatewayFinalText("direct action complete")],
        [fakeGatewayPermissionDecision("ask", "unused_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Print the working directory."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr.toLowerCase()).not.toContain("permission required");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      const json = JSON.parse(result.stdout.trim()) as {
        tool_calls: Array<{ name: string; status: string }>;
      };
      expect(json.tool_calls).toContainEqual(
        expect.objectContaining({ name: "terminal", status: "success" }),
      );
    },
    TIMEOUT,
  );

  test(
    "configured wildcard commands cannot absorb shell operators or substitutions",
    async () => {
      const root = createIsolatedRoot();
      const operatorMarker = join(root.workspace, "operator-bypass-must-not-run");
      const substitutionMarker = join(
        root.workspace,
        "substitution-bypass-must-not-run",
      );
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { "*": { "printf *": "allow" } },
        }),
      );
      const gateway = startGateway(
        [
          commandCall(
            `printf safe && touch ${JSON.stringify(operatorMarker)}`,
            "operator_bypass",
          ),
          (body) => {
            expect(body).toContain("auto_denied");
            return commandCall(
              `printf "$(touch ${substitutionMarker})"`,
              "substitution_bypass",
            );
          },
          (body) => {
            expect(body).toContain("auto_denied");
            return commandCall("printf safe", "static_command");
          },
          fakeGatewayFinalText("static command complete"),
        ],
        [
          fakeGatewayPermissionDecision("ask", "operator_requires_review"),
          fakeGatewayPermissionDecision("ask", "substitution_requires_review"),
        ],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Exercise configured commands safely."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(operatorMarker)).toBe(false);
      expect(existsSync(substitutionMarker)).toBe(false);
      expect(gateway.classifierRequests).toHaveLength(2);
      expect(gateway.requests).toHaveLength(4);
      expect(result.stdout).toContain("static command complete");
    },
    TIMEOUT,
  );

  test(
    "an exact read-only git status bypasses automatic review",
    async () => {
      const root = createIsolatedRoot();
      const initialized = Bun.spawnSync(["/usr/bin/git", "init", "--quiet"], {
        cwd: root.workspace,
      });
      expect(initialized.exitCode).toBe(0);
      const gateway = startGateway(
        [
          commandCall("git status --short --branch", "direct_git_status"),
          fakeGatewayFinalText("git inspection complete"),
        ],
        [fakeGatewayPermissionDecision("allow", "approved_git_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect repository status."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      const json = JSON.parse(result.stdout.trim()) as {
        tool_calls: Array<{ name: string; status: string }>;
      };
      expect(json.tool_calls).toContainEqual(
        expect.objectContaining({ name: "terminal", status: "success" }),
      );
    },
    TIMEOUT,
  );

  test(
    "clean direct reads bypass review and PATH while destructive commands stay blocked",
    async () => {
      const root = createIsolatedRoot();
      runGit(root.workspace, ["init", "--quiet"]);
      const shadowMarker = join(root.root, "shadow-git-must-not-run");
      const shadowBin = installRecorder(root, "git", shadowMarker);
      const gateway = startGateway(
        [
          fakeGatewaySse([
            {
              type: "tool-call",
              toolCallId: "clean_direct_pwd",
              toolName: "terminal",
              input: { action: "exec", command: "pwd", profile: "clean" },
            },
            {
              type: "tool-call",
              toolCallId: "clean_direct_git_status",
              toolName: "terminal",
              input: {
                action: "exec",
                command: "git status --short",
                profile: "clean",
              },
            },
            {
              type: "tool-call",
              toolCallId: "clean_blocked_reset",
              toolName: "terminal",
              input: {
                action: "exec",
                command: "git reset --hard",
                profile: "clean",
              },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          (body) => {
            expect(toolResultText(body, "clean_direct_pwd")).toContain("exit_code=0");
            expect(toolResultText(body, "clean_direct_git_status")).toContain("exit_code=0");
            expect(toolResultText(body, "clean_blocked_reset")).toContain("auto_denied");
            return fakeGatewayFinalText("Clean command group complete.");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "must_not_review_clean_reads")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Run the mixed clean command group."],
        {
          cwd: root.workspace,
          env: {
            ...gatewayEnv(root, gateway),
            PATH: `${shadowBin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(
        result.code,
        `stdout: ${result.stdout}\nstderr: ${result.stderr}`,
      ).toBe(0);
      expect(result.stderr).not.toContain("panic");
      expect(result.stderr).not.toContain("error:");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(existsSync(shadowMarker)).toBe(false);
      const json = JSON.parse(result.stdout.trim()) as {
        tool_calls: Array<{ name: string; status: string }>;
      };
      const terminalStatuses = json.tool_calls
        .filter(({ name }) => name === "terminal")
        .map(({ status }) => status);
      expect(terminalStatuses.filter((status) => status === "success")).toHaveLength(2);
      expect(terminalStatuses.filter((status) => status === "error")).toHaveLength(1);
      expect(result.stdout).toContain("Clean command group complete.");
    },
    TIMEOUT,
  );

  test(
    "direct destructive commands replan before reviewer allow",
    async () => {
      for (const [name, command] of [
        ["rm", "rm disposable.txt"],
        ["rmdir", "rmdir disposable-dir"],
        ["unlink", "unlink disposable-link"],
        ["shred", "shred disposable.txt"],
        ["git_clean", "git clean -fd"],
        ["git_rm", "git rm tracked.txt"],
        ["git_rm_separator", "git rm -- -n"],
        ["git_clean_separator", "git clean -f -- -n"],
        ["git_clean_exclude_short", "git clean -f -e --dry-run"],
        ["git_clean_exclude_long", "git clean -f --exclude --dry-run"],
        ["git_reset", "git reset --hard HEAD~1"],
        ["git_reset_boundary", "git reset --hard; printf ok"],
        ["compound_rm", "pwd && rm compound.txt"],
        ["rm_boundary", "rm victim; printf ok"],
        ["escaped_space_rm", "printf foo\\ #bar; rm victim"],
      ] as const) {
        const root = createIsolatedRoot();
        const marker = join(root.root, `${name}-must-not-run`);
        let bin = installRecorder(root, "rm", marker);
        for (const executable of ["rmdir", "unlink", "shred", "git"]) {
          bin = installRecorder(root, executable, marker);
        }
        const gateway = startGateway(
          [
            cleanCommandCall(command, `deterministic_${name}`),
            (body) => {
              expect(body).toContain("auto_denied");
              return fakeGatewayFinalText(`${name} replanned`);
            },
          ],
          [fakeGatewayPermissionDecision("allow", `must_not_review_${name}`)],
        );

        const result = await runFx(
          ["ask", "--quiet", "--json", "--no-save", `Exercise ${name} safely.`],
          {
            cwd: root.workspace,
            env: {
              ...gatewayEnv(root, gateway),
              PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
            },
            timeoutMs: TIMEOUT,
          },
        );

        expect(
          result.code,
          `command: ${command}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
        ).toBe(0);
        expect(result.stdout).toContain(`${name} replanned`);
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(gateway.requests).toHaveLength(2);
        expect(existsSync(marker)).toBe(false);
      }
    },
    TIMEOUT,
  );

  test(
    "delete_file replans before reviewer allow and preserves the file",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "keep.txt");
      writeFileSync(target, "keep\n");
      const gateway = startGateway(
        [
          fakeGatewayToolCall("deterministic_delete", "delete_file", {
            path: target,
          }),
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayFinalText("delete replanned");
          },
        ],
        [fakeGatewayPermissionDecision("allow", "must_not_review_delete")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Keep the file intact."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("delete replanned");
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(readFileSync(target, "utf8")).toBe("keep\n");
    },
    TIMEOUT,
  );

  test(
    "git checkout hooks remain reviewer owned",
    async () => {
      for (const hookMode of ["default", "configured"] as const) {
        const root = createIsolatedRoot();
        runGit(root.workspace, ["init", "--quiet", "--initial-branch=main"]);
        runGit(root.workspace, ["config", "user.name", "Fixture"]);
        runGit(root.workspace, ["config", "user.email", "fixture@example.com"]);
        writeFileSync(join(root.workspace, "tracked.txt"), "main\n");
        runGit(root.workspace, ["add", "tracked.txt"]);
        runGit(root.workspace, ["commit", "--quiet", "-m", "initial"]);
        runGit(root.workspace, ["branch", "feature/repro"]);

        const marker = join(root.root, `${hookMode}-checkout-hook-must-not-run`);
        const hooks = hookMode === "default"
          ? join(root.workspace, ".git", "hooks")
          : join(root.root, "configured-hooks");
        mkdirSync(hooks, { recursive: true });
        if (hookMode === "configured") {
          runGit(root.workspace, ["config", "core.hooksPath", hooks]);
        }
        const hook = join(hooks, "post-checkout");
        writeFileSync(
          hook,
          `#!/bin/sh\nprintf hook > ${JSON.stringify(marker)}\n`,
        );
        chmodSync(hook, 0o755);

        const gateway = startGateway(
          [
            cleanCommandCall("git checkout feature/repro", `${hookMode}_checkout`),
            (body) => {
              expect(body).toContain("auto_denied");
              return fakeGatewayFinalText("checkout remained blocked");
            },
          ],
          [fakeGatewayPermissionDecision("ask", `${hookMode}_checkout_review`)],
        );
        const result = await runFx(
          ["ask", "--quiet", "--json", "--no-save", "Do not run repository hooks."],
          {
            cwd: root.workspace,
            env: gatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
        expect(gateway.classifierRequests).toHaveLength(1);
        expect(existsSync(marker)).toBe(false);
        expect(runGit(root.workspace, ["branch", "--show-current"]).trim()).toBe("main");
      }
    },
    TIMEOUT,
  );

  test(
    "git pull post-merge hook remains reviewer owned",
    async () => {
      const root = createIsolatedRoot();
      const remote = join(root.root, "remote.git");
      const seed = join(root.root, "seed");
      const probe = join(root.root, "probe");
      mkdirSync(seed);
      runGit(root.root, ["init", "--quiet", "--bare", remote]);
      runGit(seed, ["init", "--quiet", "--initial-branch=main"]);
      runGit(seed, ["config", "user.name", "Fixture"]);
      runGit(seed, ["config", "user.email", "fixture@example.com"]);
      writeFileSync(join(seed, "tracked.txt"), "initial\n");
      runGit(seed, ["add", "tracked.txt"]);
      runGit(seed, ["commit", "--quiet", "-m", "initial"]);
      runGit(seed, ["remote", "add", "origin", remote]);
      runGit(seed, ["push", "--quiet", "-u", "origin", "main"]);
      runGit(root.root, [
        `--git-dir=${remote}`,
        "symbolic-ref",
        "HEAD",
        "refs/heads/main",
      ]);
      runGit(root.root, ["clone", "--quiet", remote, root.workspace]);
      runGit(root.root, ["clone", "--quiet", remote, probe]);

      const blockedMarker = join(root.root, "pull-hook-must-not-run");
      const probeMarker = join(root.root, "pull-hook-qualification-ran");
      for (const [repository, marker] of [
        [root.workspace, blockedMarker],
        [probe, probeMarker],
      ] as const) {
        const hook = join(repository, ".git", "hooks", "post-merge");
        writeFileSync(
          hook,
          `#!/bin/sh\nprintf hook > ${JSON.stringify(marker)}\n`,
        );
        chmodSync(hook, 0o755);
      }

      writeFileSync(join(seed, "tracked.txt"), "updated\n");
      runGit(seed, ["add", "tracked.txt"]);
      runGit(seed, ["commit", "--quiet", "-m", "update"]);
      runGit(seed, ["push", "--quiet", "origin", "main"]);
      runGit(probe, ["pull", "--quiet", "--ff-only"]);
      expect(existsSync(probeMarker)).toBe(true);

      const gateway = startGateway(
        [
          cleanCommandCall("git pull --ff-only", "pull_with_hook"),
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayFinalText("pull remained blocked");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "pull_hook_review")],
      );
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Do not run pull hooks."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(existsSync(blockedMarker)).toBe(false);
      expect(readFileSync(join(root.workspace, "tracked.txt"), "utf8")).toBe(
        "initial\n",
      );
    },
    TIMEOUT,
  );

  test(
    "rtk remains reviewer owned as an unresolved executable boundary",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.root, "rtk-must-not-run");
      const bin = installRecorder(root, "rtk", marker);
      const gateway = startGateway(
        [
          cleanCommandCall("rtk git status --short", "review_rtk"),
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayFinalText("rtk remained blocked");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "rtk_review")],
      );
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Do not run unresolved wrappers."],
        {
          cwd: root.workspace,
          env: {
            ...gatewayEnv(root, gateway),
            PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "existing replacement and startup targets remain reviewer owned",
    async () => {
      const root = createIsolatedRoot();
      const copySource = join(root.root, "copy-source.txt");
      const copyDestination = join(root.root, "copy-destination.txt");
      const renameSource = join(root.root, "rename-source.txt");
      const renameDestination = join(root.root, "rename-destination.txt");
      const startup = join(root.home, ".zshrc");
      writeFileSync(copySource, "copy source\n");
      writeFileSync(copyDestination, "copy destination\n");
      writeFileSync(renameSource, "rename source\n");
      writeFileSync(renameDestination, "rename destination\n");
      writeFileSync(startup, "startup before\n");

      const gateway = startGateway(
        [
          fakeGatewayToolCall("review_copy", "copy_file", {
            source: copySource,
            destination: copyDestination,
          }),
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayToolCall("review_rename", "rename_file", {
              old_path: renameSource,
              new_path: renameDestination,
            });
          },
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayToolCall("review_startup", "write_file", {
              path: startup,
              content: "startup after\n",
            });
          },
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayFinalText("replacement effects stayed blocked");
          },
        ],
        [
          fakeGatewayPermissionDecision("ask", "copy_review"),
          fakeGatewayPermissionDecision("ask", "rename_review"),
          fakeGatewayPermissionDecision("ask", "startup_review"),
        ],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Preserve every existing target."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(gateway.classifierRequests).toHaveLength(3);
      expect(readFileSync(copySource, "utf8")).toBe("copy source\n");
      expect(readFileSync(copyDestination, "utf8")).toBe("copy destination\n");
      expect(readFileSync(renameSource, "utf8")).toBe("rename source\n");
      expect(readFileSync(renameDestination, "utf8")).toBe("rename destination\n");
      expect(readFileSync(startup, "utf8")).toBe("startup before\n");
    },
    TIMEOUT,
  );

  test(
    "oversized history keeps the newest recent request in reviewer authority",
    async () => {
      const root = createIsolatedRoot();
      const blockedMarker = join(root.workspace, "oversized-history-must-not-run");
      const gateway = startGateway(
        [
          fakeGatewayFinalText("first turn complete"),
          fakeGatewayFinalText("older middle turn complete"),
          fakeGatewayFinalText("newest recent turn complete"),
          commandCall(`touch ${JSON.stringify(blockedMarker)}`, "oversized_history_blocked"),
          fakeGatewayFinalText("oversized history denial handled"),
        ],
        [fakeGatewayPermissionDecision("ask", "oversized_history_review")],
      );
      const env = gatewayEnv(root, gateway);
      const firstPrompt = `first-required-marker ${"a".repeat(4096)}`;
      const olderPrompt = `older-middle-marker ${"b".repeat(4096)}`;
      const recentPrompt = `newest-recent-required-marker ${"c".repeat(4096)}`;
      const currentPrompt = `current-required-marker ${"d".repeat(4096)}`;

      const first = await runFx(["ask", "--quiet", "--json", firstPrompt], {
        cwd: root.workspace,
        env,
        timeoutMs: TIMEOUT,
      });
      expect(first.code).toBe(0);
      const sessionIds = readdirSync(join(root.home, ".fx", "sessions"), {
        withFileTypes: true,
      })
        .filter((entry) =>
          entry.isDirectory() &&
          existsSync(join(root.home, ".fx", "sessions", entry.name, "session.json"))
        )
        .map((entry) => entry.name);
      expect(sessionIds).toHaveLength(1);
      const sessionId = sessionIds[0]!;

      for (const prompt of [olderPrompt, recentPrompt]) {
        const turn = await runFx(
          ["ask", "--quiet", "--json", "--resume-id", sessionId, prompt],
          { cwd: root.workspace, env, timeoutMs: TIMEOUT },
        );
        expect(turn.code).toBe(0);
      }

      const current = await runFx(
        ["ask", "--quiet", "--json", "--resume-id", sessionId, currentPrompt],
        { cwd: root.workspace, env, timeoutMs: TIMEOUT },
      );

      expect(current.code).toBe(0);
      expect(current.stdout).toContain("oversized history denial handled");
      expect(existsSync(blockedMarker)).toBe(false);
      expect(gateway.classifierRequests).toHaveLength(1);
      const reviewerPayload = JSON.parse(gateway.classifierRequests[0]!.body) as {
        prompt: Array<{
          role: string;
          content: Array<{ type: string; text?: string }>;
        }>;
      };
      const rootMessage = reviewerPayload.prompt[0];
      expect(rootMessage?.role).toBe("user");
      const rootContext = (rootMessage?.content ?? [])
        .filter((part) => part.type === "text")
        .map((part) => part.text ?? "")
        .join("");
      expect(Buffer.byteLength(rootContext)).toBeLessThanOrEqual(1024);
      expect(rootContext).toContain("current-required-marker");
      expect(rootContext).toContain("first-required-marker");
      expect(rootContext).toContain("newest-recent-required-marker");
      expect(rootContext).not.toContain("older-middle-marker");
    },
    TIMEOUT,
  );

  test(
    "a first automatic block returns to the agent for a safe replan",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { pwd: "allow" } },
        }),
      );
      const rejectedMarker = join(root.workspace, "rejected-action-must-not-run");
      const gateway = startGateway(
        [
          commandCall(`touch ${JSON.stringify(rejectedMarker)}`, "rejected_action"),
          (body) => {
            expect(body).toContain("auto_denied");
            expect(body).toContain("rejected_action");
            return commandCall("pwd", "safe_replan");
          },
          (body) => {
            expect(body).toContain("safe_replan");
            return fakeGatewayFinalText("safe replan complete");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "reject_first_action")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Complete the task safely."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr.toLowerCase()).not.toContain("permission required");
      expect(existsSync(rejectedMarker)).toBe(false);
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.classifierRequests).toHaveLength(1);
      const json = JSON.parse(result.stdout.trim()) as { output: string };
      expect(json.output).toContain("safe replan complete");
    },
    TIMEOUT,
  );

  test(
    "headless auto mode finishes normally after four blocked response groups",
    async () => {
      const root = createIsolatedRoot();
      const markers = Array.from(
        { length: 4 },
        (_, index) => join(root.workspace, `blocked-action-${index + 1}-must-not-run`),
      );
      const gateway = startGateway(
        [
          ...markers.map((marker, index) => (body?: string) => {
            if (index > 0) expect(body).toContain("auto_denied");
            if (index === 3) {
              expect(body).not.toContain('"tools":[]');
              expect(body).not.toContain('"toolChoice":{"type":"none"}');
            }
            return commandCall(`touch ${JSON.stringify(marker)}`, `blocked_action_${index + 1}`);
          }),
        ],
        Array.from(
          { length: 4 },
          (_, index) => fakeGatewayPermissionDecision("ask", `blocked_review_${index + 1}`),
        ),
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Try the task without unsafe actions."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr).not.toContain("permission required");
      expect(result.stderr).not.toContain("noninteractive_permission_prompt_unavailable");
      expect(gateway.requests).toHaveLength(4);
      expect(gateway.classifierRequests).toHaveLength(4);
      const json = JSON.parse(result.stdout.trim()) as {
        output: string;
        steps: number;
      };
      expect(json.output).toContain(
        "I couldn't continue because the required actions were blocked by automatic safety checks.",
      );
      expect(json.steps).toBe(4);
      for (const marker of markers) expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "standalone quiet stays silent after automatic recovery exhaustion",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "quiet-recovery-must-not-run");
      const command = `touch ${JSON.stringify(marker)}`;
      const gateway = startGateway(
        Array.from({ length: 4 }, (_, index) => (body?: string) => {
          if (index > 0) expect(body).toContain("auto_denied");
          return commandCall(command, `quiet_blocked_${index + 1}`);
        }),
        [fakeGatewayPermissionDecision("ask", "quiet_blocked_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--no-save", "Try the blocked action safely."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toBe("");
      expect(result.stderr).not.toContain("permission required");
      expect(result.stderr).not.toContain("NonInteractivePermissionRequired");
      expect(result.stderr).not.toContain(
        "I couldn't continue because the required actions were blocked by automatic safety checks.",
      );
      expect(gateway.requests).toHaveLength(4);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "equivalent denied wrappers are reviewed once and recovery continues",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "equivalent-denial-must-not-run");
      const direct = `touch ${JSON.stringify(marker)}`;
      const wrapped = `sh -c '${direct}'`;
      const gateway = startGateway(
        [
          commandCall(direct, "direct_denial"),
          (body) => {
            expect(body).toContain("auto_denied");
            return commandCall(wrapped, "wrapped_denial");
          },
          (body) => {
            expect(body).toContain("auto_denied");
            return fakeGatewayFinalText("Equivalent denial handled once.");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "single_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Try the action safely."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Equivalent denial handled once.");
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "a mixed success batch resets automatic recovery",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { pwd: "allow" } },
        }),
      );
      const markers = Array.from(
        { length: 3 },
        (_, index) => join(root.workspace, `mixed-blocked-${index + 1}-must-not-run`),
      );
      const gateway = startGateway(
        [
          commandCall(`touch ${JSON.stringify(markers[0]!)}`, "mixed_block_1"),
          commandCall(`touch ${JSON.stringify(markers[1]!)}`, "mixed_block_2"),
          fakeGatewaySse([
            {
              type: "tool-call",
              toolCallId: "mixed_block_3",
              toolName: "terminal",
              input: { action: "exec", command: `touch ${JSON.stringify(markers[2]!)}` },
            },
            {
              type: "tool-call",
              toolCallId: "mixed_safe_pwd",
              toolName: "terminal",
              input: { action: "exec", command: "pwd" },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          (body) => {
            expect(body).not.toContain('"tools":[]');
            expect(body).not.toContain('"toolChoice":{"type":"none"}');
            return fakeGatewayFinalText("Mixed success recovery continued.");
          },
        ],
        [
          fakeGatewayPermissionDecision("ask", "mixed_review_1"),
          fakeGatewayPermissionDecision("ask", "mixed_review_2"),
          fakeGatewayPermissionDecision("ask", "mixed_review_3"),
        ],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Use safe alternatives where needed."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Mixed success recovery continued.");
      expect(gateway.requests).toHaveLength(4);
      expect(gateway.classifierRequests).toHaveLength(3);
      for (const marker of markers) expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "a prompt-capable host also lets the agent recover before asking the user",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { pwd: "allow" } },
        }),
      );
      const rejectedMarker = join(root.workspace, "tui-rejected-action-must-not-run");
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      const gateway = startGateway(
        [
          commandCall(`touch ${JSON.stringify(rejectedMarker)}`, "tui_rejected_action"),
          (body) => {
            expect(body).toContain("auto_denied");
            return commandCall("pwd", "tui_safe_replan");
          },
          fakeGatewayFinalText("TUI safe replan complete"),
        ],
        [fakeGatewayPermissionDecision("ask", "tui_reject_first_action")],
      );

      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 120,
        height: 40,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Complete the task safely.");
      const scrollback = await waitForEither(
        activeSession,
        ["TUI safe replan complete", COMMAND_APPROVAL_PROMPT],
        TIMEOUT,
      );

      expect(scrollback).toContain("TUI safe replan complete");
      expect(scrollback).not.toContain(COMMAND_APPROVAL_PROMPT);
      expect(existsSync(rejectedMarker)).toBe(false);
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "saved-session allow survives restart and bypasses automatic review",
    async () => {
      const root = createIsolatedRoot();
      const allowedMarker = join(root.workspace, "saved-allow-ran");
      const allowedCommand = `touch ${JSON.stringify(allowedMarker)}`;
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { [allowedCommand]: "ask" } },
        }),
      );
      const gateway = startGateway([
        fakeGatewayFinalText("allow session initialized"),
        commandCall(allowedCommand, "saved_allow_action"),
        fakeGatewayFinalText("saved allow complete"),
      ]);
      const stderrPath = join(root.root, "saved-allow-stderr.log");
      writeFileSync(stderrPath, "");
      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 140,
        height: 42,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Initialize the saved allow session.");
      await activeSession.waitForText("allow session initialized", TIMEOUT);
      await activeSession.sendText(
        `/permissions remember allow terminal ${JSON.stringify({ action: "exec", command: allowedCommand })}`,
      );
      await activeSession.waitForText("Remember allow for this saved session", TIMEOUT);
      await activeSession.sendKeys("1");
      await activeSession.waitForText("saved-session permission rule updated", TIMEOUT);
      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;

      const sessionIds = readdirSync(join(root.home, ".fx", "sessions"), {
        withFileTypes: true,
      })
        .filter((entry) =>
          entry.isDirectory() &&
          existsSync(
            join(root.home, ".fx", "sessions", entry.name, "session.json"),
          )
        )
        .map((entry) => entry.name);
      expect(sessionIds).toHaveLength(1);
      const result = await runFx(
        [
          "ask",
          "--json",
          "--resume-id",
          sessionIds[0]!,
          "Run the exact saved action.",
        ],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(existsSync(allowedMarker)).toBe(true);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(gateway.requests).toHaveLength(3);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "an auto denial can enter exact human approval without trusting question text",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "action-bound-request-ran");
      const fakeCurl = join(root.workspace, "curl");
      writeFileSync(
        fakeCurl,
        `#!/bin/sh\nprintf 'executed\\n' >> ${JSON.stringify(marker)}\n`,
      );
      chmodSync(fakeCurl, 0o755);
      const command =
        "TOKEN='fx-secret-fixture'; ./curl -sS -H \"Authorization: Bearer ${TOKEN}\" " +
        "'https://example.invalid/stats?from=now-720m&to=now'";
      const stderrPath = join(root.root, "action-bound-stderr.log");
      const tracePath = join(root.root, "action-bound-trace.log");
      writeFileSync(stderrPath, "");
      let approvalRequestId = "";
      const gateway = startGateway(
        [
          commandCall(command, "secret_request_denied"),
          (body) => {
            const match = body.match(/approval_request_id[^0-9a-f]+([0-9a-f]{64})/);
            expect(match).not.toBeNull();
            approvalRequestId = match![1]!;
            return fakeGatewayToolCall("approve_exact_action", "ask_user_question", {
              permission_request_id: approvalRequestId,
              questions: [{
                question: "Approve exact action?",
                options: [
                  { label: "Allow once", description: "Run only the bound action." },
                  { label: "Deny", description: "Keep the action blocked." },
                ],
              }],
            });
          },
          (body) => {
            expect(body).toContain(approvalRequestId);
            expect(body).toContain('\\"authorized\\":true');
            return commandCall(command, "secret_request_retry");
          },
          fakeGatewayFinalText("Action-bound request complete"),
        ],
        [fakeGatewayPermissionDecision("ask", "secret_request_review")],
      );

      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: {
          ...gatewayEnv(root, gateway),
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "permission,tool",
        },
        stderrPath,
        width: 140,
        height: 42,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Use the same token and run the 12-hour request.");
      const approvalPane = await waitForEither(
        activeSession,
        [COMMAND_APPROVAL_PROMPT, "Approve exact action?"],
        TIMEOUT,
      );
      expect(approvalPane).toContain(COMMAND_APPROVAL_PROMPT);
      expect(approvalPane).toContain("curl");
      expect(existsSync(marker)).toBe(false);
      await activeSession.sendKeys("1");
      await activeSession.waitForText("Action-bound request complete", TIMEOUT);

      expect(readFileSync(marker, "utf8")).toBe("executed\n");
      const trace = readFileSync(tracePath, "utf8");
      expect(gateway.classifierRequests, trace).toHaveLength(0);
      expect(trace).toContain("fallback_reason=invalid_or_unavailable");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;
    },
    TIMEOUT,
  );

  test(
    "a noninteractive action-bound request stays recoverable and effect free",
    async () => {
      const root = createIsolatedRoot();
      const marker = join(root.workspace, "headless-approval-must-not-run");
      const command = `touch ${JSON.stringify(marker)}`;
      let approvalRequestId = "";
      const gateway = startGateway(
        [
          commandCall(command, "headless_denied"),
          (body) => {
            const match = body.match(/approval_request_id[^0-9a-f]+([0-9a-f]{64})/);
            expect(match).not.toBeNull();
            approvalRequestId = match![1]!;
            return fakeGatewayToolCall("headless_approval", "ask_user_question", {
              permission_request_id: approvalRequestId,
              questions: [{
                question: "Approve exact action?",
                options: [{ label: "Allow once" }, { label: "Deny" }],
              }],
            });
          },
          (body) => {
            expect(body).toContain(approvalRequestId);
            expect(body).toContain('\\"authorized\\":false');
            expect(body).toContain('\\"decision\\":\\"permission_required');
            return fakeGatewayFinalText("Headless approval needs user direction.");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "headless_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Try the action, then ask if needed."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(
        result.code,
        `stdout=${result.stdout}\nstderr=${result.stderr}`,
      ).toBe(0);
      expect(result.stdout).toContain("Headless approval needs user direction.");
      expect(result.stdout).not.toContain("NonInteractivePermissionRequired");
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "saved-session deny is confirmed, enforced over configured allow, listed, and revoked by id",
    async () => {
      const root = createIsolatedRoot();
      const blockedMarker = join(root.workspace, "saved-deny-must-not-run");
      const blockedCommand = `touch ${JSON.stringify(blockedMarker)}`;
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission: { bash: { [blockedCommand]: "allow", pwd: "allow" } },
        }),
      );
      const gateway = startGateway([
        fakeGatewayFinalText("session initialized"),
        commandCall(blockedCommand, "saved_deny_blocked"),
        (body) => {
          expect(body).toContain("policy_denied");
          return commandCall("pwd", "saved_deny_replan");
        },
        fakeGatewayFinalText("saved deny replan complete"),
      ]);
      const stderrPath = join(root.root, "saved-deny-stderr.log");
      writeFileSync(stderrPath, "");
      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 140,
        height: 42,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Initialize this saved session.");
      await activeSession.waitForText("session initialized", TIMEOUT);
      await activeSession.sendText(
        `/permissions remember deny terminal ${JSON.stringify({ action: "exec", command: blockedCommand })}`,
      );
      await activeSession.waitForText("Remember deny for this saved session", TIMEOUT);
      await activeSession.sendKeys("1");
      await activeSession.waitForText("saved-session permission rule updated", TIMEOUT);

      await activeSession.sendText("/permissions");
      await activeSession.waitForText("saved-session permission rules (1):", TIMEOUT);
      const listed = await activeSession.captureFullScrollback();
      const idMatch = listed.match(
        /saved-session permission rules \(1\):\n\s*(\d+) deny/,
      );
      expect(idMatch).not.toBeNull();
      const ruleId = idMatch![1];

      await activeSession.sendText("Complete the configured action safely.");
      await activeSession.waitForText("saved deny replan complete", TIMEOUT);
      expect(existsSync(blockedMarker)).toBe(false);
      expect(gateway.classifierRequests).toHaveLength(0);

      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText(`/permissions revoke ${ruleId}`);
      await activeSession.waitForText("Revoke this saved-session permission rule?", TIMEOUT);
      await activeSession.sendKeys("1");
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("/permissions");
      await activeSession.waitForText("saved-session permission rules: none", TIMEOUT);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;
    },
    TIMEOUT,
  );
});
