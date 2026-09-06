import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewaySse,
  fakeGatewaySerializedToolCall,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const TERMINAL_FIXTURE_SHELL = terminalFixtureShell();
const MARKDOWN =
  "# Ask presentation\n\n" +
  "**bold** and [docs](https://example.com)\n\n" +
  "- first item\n- second item\n\n---\n\n" +
  "| Name | Value |\n| --- | --- |\n| one | two |\n\n" +
  "```zig\nconst answer: u8 = 42;\n```\n";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  await Promise.all(roots.map(waitForTerminalHostExit));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

async function waitForTerminalHostExit(root: string): Promise<void> {
  const identityPath = join(root, "home", ".fx", "terminal-host-v7", "host.json");
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal host did not exit for ${root}`);
}

function createRoot() {
  const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-presentation-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  roots.push(root);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function createShortRoot() {
  const root = realpathSync(mkdtempSync("/tmp/fx-ask-terminal-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  roots.push(root);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function gatewayEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-ask-presentation-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function terminalCommand(args: string[]): string {
  const fx = [FX_BIN, ...args].map(shellQuote).join(" ");
  const script = `${fx}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
  return `/bin/sh -c ${shellQuote(script)}`;
}

function fakeGatewayStreamingText(lines: string[], delayMs: number) {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream<Uint8Array>({
      async start(controller) {
        for (const line of lines) {
          controller.enqueue(encoder.encode(
            `data: ${JSON.stringify({
              type: "text-delta",
              id: "answer_1",
              delta: `${line}\n`,
            })}\n\n`,
          ));
          if (delayMs > 0) await Bun.sleep(delayMs);
        }
        controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 3 },
              outputTokens: { total: lines.length },
            },
          })}\n\ndata: [DONE]\n\n`,
        ));
        controller.close();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

describe("fx ask presentation", () => {
  test("redirected command output separates the next tool header", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "no-final-newline",
          toolName: "shell",
          input: { request: { action: "run", profile: "clean", yield_time_ms: 30_000, command: "printf no-final-newline" } },
        },
        {
          type: "tool-call",
          toolCallId: "next-command",
          toolName: "shell",
          input: { request: { action: "run", profile: "clean", yield_time_ms: 30_000, command: "printf 'next-output\\n'" } },
        },
        {
          type: "finish",
          finishReason: { unified: "tool-calls", raw: "tool-calls" },
        },
      ]),
      fakeGatewayFinalText("Commands complete.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "--no-color", "Run both commands."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(result.code).toBe(0);
    expect(result.stderr).toContain("Running printf no-final-newline\n");
    expect(result.stderr).toContain("Running printf 'next-output\\n'\n");
    expect(JSON.parse(result.stdout).output).toBe("Commands complete.\n");
  }, TIMEOUT);

  test("no-save advertises process-local shell actions and preserves run profiles", async () => {
    const configuredShell = userInfo().shell;
    if (!configuredShell.endsWith("/bash") && !configuredShell.endsWith("/zsh")) return;

    const root = createRoot();
    if (configuredShell.endsWith("/zsh")) {
      writeFileSync(
        join(root.home, ".zprofile"),
        "export FX_PROFILE_LOGIN=login\nexport PATH=\"$HOME/profile-bin:$PATH\"\n",
      );
      writeFileSync(
        join(root.home, ".zshrc"),
        "export FX_PROFILE_RC=rc\nalias fx_profile_alias='printf alias-user'\n" +
          "fx_profile_function() { printf function-user; }\n",
      );
    } else {
      writeFileSync(
        join(root.home, ".bash_profile"),
        "export FX_PROFILE_LOGIN=login\nexport PATH=\"$HOME/profile-bin:$PATH\"\n" +
          "source \"$HOME/.bashrc\"\n",
      );
      writeFileSync(
        join(root.home, ".bashrc"),
        "export FX_PROFILE_RC=rc\nalias fx_profile_alias='printf alias-user'\n" +
          "fx_profile_function() { printf function-user; }\n",
      );
    }

    const profileCommand =
      "printf 'mode=%s:%s:' \"${FX_PROFILE_LOGIN-unset}\" \"${FX_PROFILE_RC-unset}\"; " +
      "case :\"$PATH\": in *:\"$HOME/profile-bin\":*) printf 'path-user:';; *) printf 'path-clean:';; esac; " +
      "if alias fx_profile_alias >/dev/null 2>&1; then fx_profile_alias; else printf no-alias; fi; printf ':'; " +
      "if command -v fx_profile_function >/dev/null; then fx_profile_function; else printf no-function; fi";
    const nestedExecMarker = join(root.workspace, "nested-no-save-ran");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell-omitted", "shell", {
        request: { action: "run", command: profileCommand, yield_time_ms: 30_000 },
      }),
      fakeGatewayToolCall("shell-clean", "shell", {
        request: { action: "run", command: profileCommand, profile: "clean", yield_time_ms: 30_000 },
      }),
      fakeGatewayToolCall("shell-user", "shell", {
        request: { action: "run", command: profileCommand, profile: "user", yield_time_ms: 30_000 },
      }),
      fakeGatewayToolCall("shell-stale-tty", "shell", {
        request: {
          action: "run",
          command: "printf should-not-start",
          tty: true,
        },
      }),
      fakeGatewayToolCall("shell-nested-run", "shell", {
        request: {
          action: "run",
          profile: "clean",
          yield_time_ms: 30_000,
          command: `printf nested > ${JSON.stringify(nestedExecMarker)}`,
        },
      }),
      fakeGatewayToolCall("shell-neighbor-run", "shell", {
        request: { action: "run", profile: "clean", yield_time_ms: 30_000, command: "printf neighbor-exec" },
      }),
      fakeGatewayFinalText("Shell no-save profiles verified.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Verify shell run profiles."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout) as {
      output: string;
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.output).toBe("Shell no-save profiles verified.\n");
    expect(output.tool_calls.map(({ name, status }) => ({ name, status }))).toEqual([
      { name: "shell", status: "success" },
      { name: "shell", status: "success" },
      { name: "shell", status: "success" },
      { name: "shell", status: "error" },
      { name: "shell", status: "success" },
      { name: "shell", status: "success" },
    ]);
    expect(gateway.requests).toHaveLength(7);

    const firstRequest = JSON.parse(gateway.requests[0]!.body) as {
      tools: Array<any>;
    };
    const shellTool = firstRequest.tools.find(({ name }) => name === "shell");
    const shellSchema = shellTool?.inputSchema;
    expect(Object.keys(shellSchema?.properties ?? {})).toEqual(["request"]);
    expect(shellSchema?.required).toEqual(["request"]);
    expect(shellSchema?.additionalProperties).toBe(false);
    const branches = shellSchema?.properties?.request?.oneOf ?? [];
    expect(branches.map((branch: any) => branch.properties.action.enum[0])).toEqual([
      "run",
      "interact",
      "stop",
    ]);
    const serializedShellTool = JSON.stringify(shellTool);
    expect(serializedShellTool).not.toContain('"tty"');
    expect(serializedShellTool).not.toContain('"write"');
    expect(serializedShellTool).not.toContain('"terminal"');

    for (const requestIndex of [1, 3]) {
      expect(gateway.requests[requestIndex]!.body).toContain("mode=login:rc:path-user:");
      expect(gateway.requests[requestIndex]!.body).toContain("alias-user:function-user");
    }
    expect(gateway.requests[2]!.body).toContain("mode=unset:unset:path-clean:");
    expect(gateway.requests[2]!.body).toContain("no-alias:no-function");
    expect(gateway.requests[4]!.body).toContain("tool_execution_failed");
    expect(gateway.requests[4]!.body).toContain("tool_execution_failed");
    expect(gateway.requests[4]!.body).not.toContain("authority_denied");
    expect(gateway.requests[4]!.body).not.toContain("tool_permission_denied");
    expect(gateway.requests[5]!.body).toContain("nested");
    expect(existsSync(nestedExecMarker)).toBe(true);
    expect(gateway.requests[6]!.body).toContain("neighbor-exec");
    expect(
      existsSync(join(root.home, ".fx", "terminal-host-v7", "host.json")),
    ).toBe(false);
  }, TIMEOUT);

  test("redirected and JSON stdout preserve raw assistant Markdown", async () => {
    const root = createRoot();
    const rawGateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
    gateways.push(rawGateway);
    const raw = await runFx(["ask", "--no-save", "Render the fixture."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, rawGateway),
      timeoutMs: TIMEOUT,
    });

    expect(raw.code).toBe(0);
    expect(raw.stdout).toBe(MARKDOWN);
    expect(raw.stdout).not.toContain("\x1b");
    expect(raw.stderr).toBe("");

    const jsonGateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
    gateways.push(jsonGateway);
    const json = await runFx(
      ["ask", "--json", "--no-save", "Render the fixture."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, jsonGateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(json.code).toBe(0);
    expect(JSON.parse(json.stdout).output).toBe(MARKDOWN);
    expect(json.stdout).not.toContain("\x1b");
    expect(json.stderr).toBe("");
  }, TIMEOUT);

  test("JSON separates accumulated assistant Markdown from the completed final response", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "fixture.txt"), "fixture contents\n");
    const intermediate = "I will inspect the fixture first.\n";
    const final = "The fixture inspection is complete.";
    const gateway = startFakeGateway([
      fakeGatewaySerializedToolCall(
        "read_fixture_for_final_output",
        "read_file",
        JSON.stringify({ path: "fixture.txt" }),
        intermediate,
      ),
      fakeGatewayFinalText(final),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Inspect fixture.txt."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout) as {
      output: string;
      final_output: string;
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.output).toContain(intermediate.trim());
    expect(output.output).toContain(final.trim());
    expect(output.output.indexOf(intermediate.trim())).toBeLessThan(
      output.output.indexOf(final.trim()),
    );
    expect(output.final_output).toBe(final);
    expect(output.final_output).not.toContain(intermediate.trim());
    expect(output.tool_calls).toEqual([
      { name: "read_file", status: "success" },
    ]);
    expect(gateway.requests).toHaveLength(2);
    expect(result.stderr).toContain("Reading fixture.txt");
  }, TIMEOUT);

  test("tool recovery keeps progress updates ordered before the final response", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "fallback.txt"), "fallback contents\n");
    const initial = "I will inspect the requested file first.";
    const recovery = "The requested file was missing, so I will inspect fallback.txt next.";
    const final = "The fallback inspection is complete.";
    const gateway = startFakeGateway([
      fakeGatewaySerializedToolCall(
        "read_missing_for_progress",
        "read_file",
        JSON.stringify({ path: "missing.txt" }),
        initial,
      ),
      fakeGatewaySerializedToolCall(
        "read_fallback_for_progress",
        "read_file",
        JSON.stringify({ path: "fallback.txt" }),
        recovery,
      ),
      fakeGatewayFinalText(final),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Inspect missing.txt and recover with fallback.txt."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests).toHaveLength(3);
    const firstPrompt = (JSON.parse(gateway.requests[0]!.body) as GatewayRequestBody)
      .prompt
      .filter((message) => message.role === "system")
      .map((message) => typeof message.content === "string" ? message.content : "")
      .join("\n");
    expect(firstPrompt).toContain(
      "Before the first tool call in a tool-driven task, always send one brief user-visible update",
    );
    expect(firstPrompt).toContain("Never start the first tool silently.");
    expect(firstPrompt).toContain(
      "If another tool call will follow, always first tell the user what failed",
    );
    expect(firstPrompt).toContain("Do not narrate each routine tool call.");

    const output = JSON.parse(result.stdout) as {
      output: string;
      final_output: string;
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.output).toContain(initial);
    expect(output.output).toContain(recovery);
    expect(output.output).toContain(final);
    expect(output.output.indexOf(initial)).toBeLessThan(
      output.output.indexOf(recovery),
    );
    expect(output.output.indexOf(recovery)).toBeLessThan(
      output.output.indexOf(final),
    );
    expect(output.final_output).toBe(final);
    expect(output.tool_calls).toEqual([
      { name: "read_file", status: "error" },
      { name: "read_file", status: "success" },
    ]);
    expect(gateway.requests[1]!.body).toContain("FileNotFound");
    expect(gateway.requests[2]!.body).toContain(recovery);
    expect(result.stderr).toContain("Reading missing.txt");
    expect(result.stderr).toContain("Reading fallback.txt");
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())(
    "TTY stdout uses the Minimal transcript and compact tool group",
    async () => {
      const root = createRoot();
      writeFileSync(join(root.workspace, "fixture.txt"), "fixture contents\n");
      let releaseFinal: (() => void) | undefined;
      const finalReady = new Promise<void>((resolve) => {
        releaseFinal = resolve;
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("read_fixture", "read_file", { path: "fixture.txt" }),
        fakeGatewaySerializedToolCall(
          "read_missing",
          "read_file",
          JSON.stringify({ path: "missing.txt" }),
          "Between groups.\n",
        ),
        async () => {
          await finalReady;
          return fakeGatewayFinalText(MARKDOWN);
        },
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--auto",
          "--no-save",
          "Inspect fixture.txt and render the response.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Between groups.", TIMEOUT);
      await session.resizeWindow(104, 36);
      releaseFinal!();
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const pane = await session.capturePane();
      const scrollback = await session.captureFullScrollback();
      const escaped = await session.captureFullScrollbackEscapes();
      expect(scrollback).toContain("Inspect fixture.txt and render the response.");
      expect(pane.match(/1 tool call · 1 read/g)).toHaveLength(2);
      expect(pane).toContain("Reading fixture.txt");
      expect(pane).toContain("Between groups.");
      expect(pane).toContain("Reading missing.txt");
      expect(pane).toContain("failed");
      expect(pane).toContain("Ask presentation");
      expect(pane).toContain("bold and docs");
      expect(pane).toContain("first item");
      expect(pane).toContain("const answer: u8 = 42;");
      expect(pane).toContain("─ zig ─");
      expect(pane).not.toContain("│ const answer: u8 = 42;");
      expect(pane).not.toContain("# Ask presentation");
      expect(pane).not.toContain("**bold**");
      expect(escaped).toContain("\x1b[");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "--no-color keeps the TTY layout without fx styles or hyperlinks",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--no-color",
          "--no-save",
          "Render the no-color fixture.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const pane = await session.captureFullScrollback();
      const escaped = await session.captureFullScrollbackEscapes();
      expect(pane).toContain("Render the no-color fixture.");
      expect(pane).toContain("Ask presentation");
      expect(pane).toContain("bold and docs");
      expect(pane).toContain("const answer: u8 = 42;");
      expect(escaped).not.toMatch(/\x1b\[[0-9;]*m/);
      expect(escaped).not.toContain("\x1b]8;");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "light theme uses readable syntax colors in TTY code blocks with redirected stdin",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: `${terminalCommand([
          "ask",
          "--no-save",
          "Render the light-theme fixture.",
        ])} </dev/null`,
        cwd: root.workspace,
        env: {
          ...gatewayEnv(root.home, gateway),
          FX_THEME: "light",
          NO_COLOR: undefined,
        },
        width: 120,
        height: 40,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const escaped = await session.captureFullScrollbackEscapes();
      expect(escaped).toContain("\x1b[38;5;238mconst\x1b[39m");
      expect(escaped).not.toContain("\x1b[38;5;252mconst\x1b[39m");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY output taller than the pane survives in native scrollback",
    async () => {
      const root = createRoot();
      const answerLines = Array.from(
        { length: 60 },
        (_, index) => `ANSWER_LINE_${String(index + 1).padStart(2, "0")}`,
      );
      const gateway = startFakeGateway([
        fakeGatewaySse([
          ...answerLines.map((line) => ({
            type: "text-delta",
            id: "answer_1",
            delta: `${line}\n`,
          })),
          {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 3 },
              outputTokens: { total: 60 },
            },
          },
        ]),
      ]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--no-save",
          "Render every answer line.",
        ]),
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        width: 80,
        height: 12,
        minimumHistoryLines: 200,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      let previousIndex = -1;
      for (const line of answerLines) {
        const index = scrollback.indexOf(line);
        expect(index, line).toBeGreaterThan(previousIndex);
        previousIndex = index;
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY prints the header before output and releases while the response is open",
    async () => {
      const root = createRoot();
      const answerLines = Array.from(
        { length: 40 },
        (_, index) => `OPEN_STREAM_LINE_${String(index + 1).padStart(2, "0")}`,
      );
      let releaseOutput = () => {};
      const outputGate = new Promise<void>((resolve) => {
        releaseOutput = resolve;
      });
      let releaseResponse = () => {};
      const responseGate = new Promise<void>((resolve) => {
        releaseResponse = resolve;
      });
      const gateway = startDynamicFakeGateway(() => {
        const encoder = new TextEncoder();
        return new Response(
          new ReadableStream<Uint8Array>({
            async start(controller) {
              await outputGate;
              for (const line of answerLines) {
                controller.enqueue(encoder.encode(
                  `data: ${JSON.stringify({
                    type: "text-delta",
                    id: "answer_1",
                    delta: `${line}\n`,
                  })}\n\n`,
                ));
              }
              await responseGate;
              controller.enqueue(encoder.encode(
                `data: ${JSON.stringify({
                  type: "finish",
                  finishReason: { unified: "stop", raw: "stop" },
                  usage: {
                    inputTokens: { total: 3 },
                    outputTokens: { total: answerLines.length },
                  },
                })}\n\ndata: [DONE]\n\n`,
              ));
              controller.close();
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        );
      });
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--no-save",
          "Stream every answer line.",
        ]),
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        width: 80,
        height: 12,
        minimumHistoryLines: 200,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      try {
        const requestDeadline = Date.now() + 5_000;
        while (gateway.requestCount() === 0 && Date.now() < requestDeadline) {
          await Bun.sleep(25);
        }
        expect(gateway.requestCount()).toBe(1);

        const headerDeadline = Date.now() + 5_000;
        let initialScrollback = "";
        while (Date.now() < headerDeadline) {
          initialScrollback = await session.captureFullScrollback();
          if (
            initialScrollback.includes("Run /help for commands") &&
            initialScrollback.includes("Stream every answer line.")
          ) break;
          await Bun.sleep(25);
        }
        expect(initialScrollback).toContain("Run /help for commands");
        expect(initialScrollback).toContain("Stream every answer line.");
        expect(initialScrollback).not.toContain(answerLines[0]!);
        expect(initialScrollback.indexOf("Run /help for commands")).toBeLessThan(
          initialScrollback.indexOf("Stream every answer line."),
        );

        releaseOutput();
        const releaseDeadline = Date.now() + 5_000;
        let openScrollback = "";
        while (Date.now() < releaseDeadline) {
          openScrollback = await session.captureFullScrollback();
          if (openScrollback.includes(answerLines[0]!)) break;
          await Bun.sleep(25);
        }
        expect(openScrollback).toContain(answerLines[0]!);
      } finally {
        releaseOutput();
        releaseResponse();
      }

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const finalScrollback = await session.captureFullScrollback();
      expect(finalScrollback.split("Run /help for commands")).toHaveLength(2);
      for (const line of answerLines) {
        expect(finalScrollback.split(line)).toHaveLength(2);
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY wrapped output stays ordered and appears exactly once",
    async () => {
      const root = createRoot();
      const answerLines = Array.from(
        { length: 7 },
        (_, index) =>
          `WRAPPED_LINE_${String(index + 1).padStart(2, "0")} ${"x".repeat(190)}`,
      );
      const gateway = startFakeGateway([
        () => fakeGatewayStreamingText(answerLines, 3),
      ]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--no-save",
          "Render every wrapped answer line.",
        ]),
        cwd: root.workspace,
        env: gatewayEnv(root.home, gateway),
        width: 100,
        height: 20,
        minimumHistoryLines: 100,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText(/__FX_EXIT_[0-9]+__/, TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("__FX_EXIT_0__");
      let previousIndex = -1;
      for (const line of answerLines) {
        const marker = line.slice(0, "WRAPPED_LINE_00".length);
        const index = scrollback.indexOf(marker);
        expect(index, marker).toBeGreaterThan(previousIndex);
        expect(scrollback.split(marker)).toHaveLength(2);
        previousIndex = index;
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY Minimal hides context and auto-approval notices",
    async () => {
      const root = createRoot();
      const instructions = join(root.root, "instructions.md");
      writeFileSync(instructions, "# Fixture instructions\n");
      symlinkSync(instructions, join(root.workspace, "AGENTS.md"));
      const gateway = startFakeGateway(
        [
          fakeShellRun("write_fixture", "printf notice-test > ask-notice.txt", {
            timeout_ms: 600_000,
          }),
          fakeGatewayFinalText("Notice filtering complete.\n"),
        ],
        { classifierResponses: [fakeGatewayPermissionDecision()] },
      );
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--auto",
          "--no-save",
          "Run the notice filtering fixture.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("Run the notice filtering fixture.");
      expect(scrollback).toContain("Notice filtering complete.");
      expect(scrollback).toContain("1 tool call · 1 command");
      expect(scrollback).not.toContain("project instructions");
      expect(scrollback).not.toContain("Auto agent approved this request");
      expect(scrollback).not.toContain("● System:");
    },
    TIMEOUT,
  );
});
