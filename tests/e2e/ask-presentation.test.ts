import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { latestTraceReportPath, readTraceReport } from "./trace-report";
import { requestToolNames, toolResultText } from "./fixtures/request-body";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { EVAL_ERROR_PREFIX } from "./shell-eval-error";
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
const WIDE_TABLE =
  "| # | Choice | Direct consequences |\n" +
  "|---|---|---|\n" +
  "| 1 | **Change:** on reopen, an unfinished turn gets `turn_interrupted{reason: crash}`; it's never cut | " +
  "`recovery.json` and `recovery.asked` go away. The adapter handles a turn that ends in a tool call with no result |\n" +
  "| 8 | **Keep:** forks start only at turn boundaries (or turn 0) | Mid-turn forks deferred |\n";
const TOKEN_BREAKS_TABLE =
  "| Check | Status | Notes |\n" +
  "|---|---|---|\n" +
  "| node tsec/scripts/seed.ts update && node tsec/scripts/seed.ts check | Pass (exit 0) | 63 .js files, byte-for-byte stage1 == stage2 == seed fixpoint |\n" +
  "| TSE_BUILD_JOBS=4 node tsec/scripts/native.ts | Pass (exit 0) | 58 C units compiled and linked cleanly into native tsec (8.0 MB) |\n" +
  "| TSE_BUILD_JOBS=4 node tsec/test/run.ts --only native-const-prim-arrays,native-cow-clone,native-export-inline,cache-gc,native-stats-line,native-fast-split,build-run305,d307 | Pass (exit 0) | All 8 sections passed (O2 -Werror, ASan+UBSan live 0, 8-thread TSan 0 races, --c-dir, nm -u inline proof, cache-gc 28/28, native-stats-line 213 checks) |\n" +
  "| node tsec/test/run.ts --only query | Pass (exit 0) | All query and query layout checks passed (nullable own + --cow-reachable) |\n";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

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
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
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
    // No-save asks advertise the process-only fields, flat with one action enum.
    expect(Object.keys(shellSchema?.properties ?? {})).toEqual([
      "action",
      "command",
      "cwd",
      "profile",
      "yield_time_ms",
      "timeout_ms",
      "session_id",
      "force",
    ]);
    expect(shellSchema?.required).toEqual(["action"]);
    expect(shellSchema?.additionalProperties).toBe(false);
    expect(shellSchema?.properties?.action?.enum).toEqual(["run", "interact", "stop"]);
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
    // The refused tty run never reached the terminal store.
    expect(
      existsSync(join(root.home, ".fx"))
        ? Array.from(new Bun.Glob("**/terminal/state/record-*.json").scanSync({
          cwd: join(root.home, ".fx"),
          dot: true,
        }))
        : [],
    ).toEqual([]);
  }, TIMEOUT);

  test("a shell run returns a 35-second command as completed when it waits 45 seconds", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell-slow", "shell", {
        request: { action: "run", command: "sleep 35; printf waited-done", yield_time_ms: 45_000 },
      }),
      fakeGatewayFinalText("Slow command verified.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Run the slow fixture."], {
      cwd: root.workspace,
      env: { ...gatewayEnv(root.home, gateway), FX_SOUND: "0" },
      timeoutMs: 150_000,
    });

    expect(result.code).toBe(0);
    expect(gateway.requests).toHaveLength(2);
    // The follow-up request carries the shell result as JSON text, so its
    // quotes arrive escaped.
    const followUp = gateway.requests[1]!.body;
    expect(followUp).toContain("waited-done");
    expect(followUp).toContain(JSON.stringify('"state":"completed"').slice(1, -1));
    expect(followUp).not.toContain(JSON.stringify('"state":"running"').slice(1, -1));
  }, 150_000);

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
    expect(gateway.requests[1]!.body).toContain("Path not found: missing.txt");
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
      expect(scrollback).toContain("𝒇x v");
      expect(scrollback).toContain(FAKE_GATEWAY_MODEL);
      expect(scrollback).not.toContain("Run /help for commands");
      expect(scrollback).not.toContain("Inspect fixture.txt and render the response.");
      // Each group's only call is its header, and the failed read is marked.
      expect(pane).toContain("● Reading fixture.txt");
      expect(pane).toContain("Between groups.");
      expect(pane).toContain("● Failed: Reading missing.txt: Path not found: missing.txt");
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
    "inline code URL keeps its full target across wrapped transcript rows",
    async () => {
      const root = createRoot();
      const url = "http://localhost:3210/bench?run=https://github.com/vercel/e/actions/runs/36247033515";
      const gateway = startFakeGateway([fakeGatewayFinalText(`Open \`${url}.\`\n`)]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: FX_BIN,
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 82,
        height: 24,
        stderrPath,
      });
      sessions.push(session);

      await session.sendText("Show the URL.");
      await session.waitForText("3515.", TIMEOUT);
      const pane = await session.captureFullScrollback();
      const rows = pane.split("\n").filter((row) => row.includes("localhost:") || row.includes("3515."));
      expect(rows).toHaveLength(2);
      const escaped = await session.captureFullScrollbackEscapes();
      const target = `\x1b]8;id=fx-1;${url}\x1b\\`;
      const linkedRows = escaped.split("\n").filter((row) => row.includes(target));
      expect(linkedRows).toHaveLength(2);
      expect(linkedRows[0]).toContain("localhost:");
      expect(linkedRows[1]).toContain("3515\x1b]8;;\x1b\\.");
      expect(escaped).not.toContain(`\x1b]8;;${url}.\x1b\\`);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requestCount()).toBe(1);
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
      expect(pane).toContain("𝒇x v");
      expect(pane).toContain(FAKE_GATEWAY_MODEL);
      expect(pane).not.toContain("Run /help for commands");
      expect(pane).not.toContain("Render the no-color fixture.");
      expect(pane).toContain("Ask presentation");
      expect(pane).toContain("bold and docs");
      expect(pane).toContain("const answer: u8 = 42;");
      expect(escaped).not.toMatch(/\x1b\[[0-9;]*m/);
      expect(escaped).not.toContain("\x1b]8;");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "NO_COLOR and TERM=dumb render like --no-color",
    async () => {
      // Both standard variables turn fx ask's color off.
      for (const env of [{ NO_COLOR: "1" }, { NO_COLOR: undefined, TERM: "dumb" }]) {
        const root = createRoot();
        const gateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
        gateways.push(gateway);

        const session = await TmuxSession.create({
          isolated: true,
          cmd: terminalCommand(["ask", "--no-save", "Render the standard no-color fixture."]),
          cwd: root.workspace,
          env: { ...gatewayEnv(root.home, gateway), ...env },
          width: 120,
          height: 40,
          remainOnExit: true,
        });
        sessions.push(session);

        await session.waitForText("__FX_EXIT_0__", TIMEOUT);
        const pane = await session.captureFullScrollback();
        const escaped = await session.captureFullScrollbackEscapes();
        expect(pane).toContain("Ask presentation");
        expect(pane).toContain("const answer: u8 = 42;");
        expect(escaped).not.toMatch(/\x1b\[[0-9;]*m/);
      }
    },
    TIMEOUT * 2,
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
    "TTY tables wider than the pane wrap cells inside the grid",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText(WIDE_TABLE)]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--no-save", "Render the wide table fixture."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 72,
        height: 40,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      const grid = scrollback
        .split("\n")
        .map((line) => line.trimEnd())
        .filter((line) => /^\s*[┌│├└]/.test(line));
      expect(grid[0]).toMatch(/^\s*┌───┬─+┬─+┐$/);
      expect(grid.at(-1)).toMatch(/^\s*└───┴─+┴─+┘$/);
      expect(new Set(grid.map((line) => line.length)).size).toBe(1);
      expect(grid.some((line) => /^\s*│ 1 │ Change:/.test(line))).toBe(true);
      expect(grid.some((line) => /^\s*│   │ \S/.test(line))).toBe(true);
      expect(scrollback).not.toContain("Choice: ");
      expect(scrollback).not.toContain("Direct consequences: ");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY tables break a long token instead of widening its column",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText(TOKEN_BREAKS_TABLE)]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--no-save", "Render the check table fixture."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 100,
        height: 40,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      const lines = scrollback.split("\n").map((line) => line.trimEnd());
      const grid = lines.filter((line) => /^\s*[┌│├└]/.test(line));
      const top = lines.find((line) => line.includes("┌")) ?? "";
      const segments = top.trim().replace(/^┌/, "").replace(/┐$/, "").split("┬").map((segment) => segment.length);
      expect(segments).toEqual([42, 15, 37]);
      expect(new Set(grid.map((line) => line.length)).size).toBe(1);
      expect(Math.max(...grid.map((line) => line.length))).toBeLessThanOrEqual(100);
      expect(scrollback.split("Pass (exit 0)").length - 1).toBe(4);
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
            initialScrollback.includes("𝒇x v") &&
            initialScrollback.includes(`${FAKE_GATEWAY_MODEL} · fx ask --help`) &&
            initialScrollback.includes("• Thinking")
          ) break;
          await Bun.sleep(25);
        }
        expect(initialScrollback).toContain("𝒇x v");
        expect(initialScrollback).toContain(`${FAKE_GATEWAY_MODEL} · fx ask --help`);
        expect(initialScrollback).toContain("• Thinking");
        expect(initialScrollback).not.toContain("Run /help for commands");
        expect(initialScrollback).not.toContain("Stream every answer line.");
        expect(initialScrollback).not.toContain(answerLines[0]!);

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
      expect(finalScrollback.split(FAKE_GATEWAY_MODEL)).toHaveLength(2);
      expect(finalScrollback).not.toContain("• Thinking");
      expect(finalScrollback).not.toContain("Run /help for commands");
      expect(finalScrollback).not.toContain("Stream every answer line.");
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
      expect(scrollback).toContain("𝒇x v");
      expect(scrollback).toContain(FAKE_GATEWAY_MODEL);
      expect(scrollback).not.toContain("Run /help for commands");
      expect(scrollback).not.toContain("Run the notice filtering fixture.");
      expect(scrollback).toContain("Notice filtering complete.");
      expect(scrollback).toContain("● Running printf notice-test > ask-notice.txt");
      expect(scrollback).not.toContain("project instructions");
      expect(scrollback).not.toContain("Auto agent approved this request");
      expect(scrollback).not.toMatch(/[*✓!✗⊘i] system:/);
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY header shows plain white version and resolved CLI model, effort, and fast settings without echoing the prompt",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText("Header verified.\n")], {
        models: [
          {
            id: "anthropic/claude-sonnet-5.5",
            type: "language",
            tags: ["tool-use", "reasoning"],
            reasoning_options: [{ type: "effort", values: ["low", "medium", "high"] }],
            speed: { fast: true },
          },
        ],
      });
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand([
          "ask",
          "--no-save",
          "--model",
          "anthropic/claude-sonnet-5.5",
          "--effort",
          "high",
          "--fast",
          "Secret prompt text that must not echo.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 30,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      const escaped = await session.captureFullScrollbackEscapes();
      expect(scrollback).toContain("𝒇x v");
      expect(scrollback).toContain("· anthropic/claude-sonnet-5.5 · high · fast · fx ask --help");
      expect(scrollback).toContain("Header verified.");
      expect(scrollback).not.toContain("Run /help for commands");
      expect(scrollback).not.toContain("Secret prompt text that must not echo.");
      // Version carries bright/white hint style and model metadata carries dim style.
      expect(escaped).toMatch(
        /\x1b\[1m\x1b\[38;5;255m𝒇x\x1b\[0m \x1b\[38;5;255mv[^\x1b]+\x1b\[38;5;245m · anthropic\/claude-sonnet-5\.5 · high · fast · fx ask --help/,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY resize mid-stream preserves prior scrollback without clearing the screen",
    async () => {
      const root = createRoot();
      writeFileSync(join(root.workspace, "resize-fixture.txt"), "ok\n");
      let releaseFinal: (() => void) | undefined;
      const finalGate = new Promise<void>((resolve) => {
        releaseFinal = resolve;
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("read_resize", "read_file", { path: "resize-fixture.txt" }),
        async () => {
          await finalGate;
          return fakeGatewayFinalText("FINAL_AFTER_RESIZE\n");
        },
      ]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");

      const fxCmd = [FX_BIN, "ask", "--auto", "--no-save", "Read resize-fixture.txt."]
        .map(shellQuote)
        .join(" ");
      const script = `printf 'PRIOR_SCROLLBACK_SENTINEL\\n'; ${fxCmd}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
      const session = await TmuxSession.create({
        isolated: true,
        cmd: `/bin/sh -c ${shellQuote(script)}`,
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 100,
        height: 24,
        minimumHistoryLines: 200,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);

      try {
        await session.waitForText("● Reading resize-fixture.txt", TIMEOUT);
        await session.resizeWindow(76, 20);
        releaseFinal!();
        await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      } finally {
        releaseFinal!();
      }

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("PRIOR_SCROLLBACK_SENTINEL");
      expect(scrollback.split(FAKE_GATEWAY_MODEL)).toHaveLength(2);
      expect(scrollback).toContain("● Reading resize-fixture.txt");
      expect(scrollback).toContain("FINAL_AFTER_RESIZE");
      expect(scrollback).not.toContain("• Thinking");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY clears Thinking indicator before printing HTTP error to stderr",
    async () => {
      const root = createRoot();
      let releaseError: () => void;
      const errorGate = new Promise<void>((resolve) => {
        releaseError = resolve;
      });
      const gateway = startDynamicFakeGateway(async () => {
        await errorGate;
        return new Response(
          JSON.stringify({ error: { message: "bad request test" } }),
          {
            status: 400,
            headers: { "content-type": "application/json" },
          },
        );
      });
      gateways.push(gateway);

      const fxCmd = [
        FX_BIN,
        "ask",
        "--auto",
        "--no-save",
        "Trigger an HTTP error.",
      ]
        .map(shellQuote)
        .join(" ");
      const script = `${fxCmd}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
      const session = await TmuxSession.create({
        isolated: true,
        cmd: `/bin/sh -c ${shellQuote(script)}`,
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 96,
        height: 24,
        minimumHistoryLines: 200,
        remainOnExit: true,
      });
      sessions.push(session);

      try {
        await session.waitForText("• Thinking", TIMEOUT);
        releaseError!();
        await session.waitForText("__FX_EXIT_1__", TIMEOUT);
      } finally {
        releaseError!();
      }

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("𝒇x v");
      expect(scrollback).toContain(
        "\nfx ask: API request failed · HTTP 400 · bad request test\n",
      );
      expect(scrollback).not.toContain("• Thinking");
    },
    TIMEOUT,
  );
});

// Both login shells read these files, so the tests hold for zsh and bash.
function writeStartupFiles(home: string, body: string): void {
  writeFileSync(join(home, ".zshrc"), body);
  writeFileSync(join(home, ".bash_profile"), body);
}

function startupLoads(home: string): number {
  const log = join(home, "rc.log");
  return existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).length : 0;
}

function userShellRun(id: string, command: string) {
  return fakeGatewayToolCall(id, "shell", {
    request: { action: "run", command, yield_time_ms: 30_000 },
  });
}

function filesContaining(dir: string, needle: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return filesContaining(path, needle);
    return readFileSync(path).includes(needle) ? [path] : [];
  });
}

function occurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

describe("fx ask shell startup files", () => {
  test("user-profile commands load startup files once and reload after an edit", async () => {
    const root = createRoot();
    writeStartupFiles(
      root.home,
      "printf 'loaded\\n' >> \"$HOME/rc.log\"\n" +
        "export PATH=\"$HOME/fx-startup-marker:$PATH\"\n",
    );
    const edit = "for f in ~/.zshrc ~/.bash_profile; do " +
      "printf '%s\\n' \"alias fxlate='printf FX_RELOADED_ALIAS'\" >> \"$f\"; done";
    const gateway = startFakeGateway([
      userShellRun("path-0", "echo \"PATH=$PATH\""),
      userShellRun("path-1", "echo \"PATH=$PATH\""),
      userShellRun("path-2", "echo \"PATH=$PATH\""),
      userShellRun("edit", edit),
      userShellRun("reloaded", "fxlate"),
      fakeGatewayFinalText("Startup files checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Check the startup files."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const marker = `${root.home}/fx-startup-marker:`;
    for (const index of [1, 2, 3]) {
      expect(gateway.requests[index]!.body).toContain(`PATH=${marker}`);
    }
    expect(gateway.requests[5]!.body).toContain("FX_RELOADED_ALIAS");
    // One capture, and one more after the edit: never once per command.
    expect(startupLoads(root.home)).toBe(2);
    expect(result.stderr).not.toContain("shell snapshot unavailable");
  }, TIMEOUT);

  // Wrappers such as Socket Firewall's `pnpm` call a helper whose name starts
  // with `_`, which completion functions share.
  test("a startup-file wrapper that calls an underscore helper runs through the snapshot", async () => {
    const root = createRoot();
    writeStartupFiles(
      root.home,
      "printf 'loaded\\n' >> \"$HOME/rc.log\"\n" +
        "_fx_wrap_helper() { printf 'FX_WRAPPED_HELPER_OK %s\\n' \"$*\"; }\n" +
        "fxwrapped() { _fx_wrap_helper fxwrapped \"$@\"; }\n",
    );
    const gateway = startFakeGateway([
      userShellRun("wrapped", "fxwrapped install"),
      fakeGatewayFinalText("Wrapper checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Run the wrapped command."],
      { cwd: root.workspace, env: { ...gatewayEnv(root.home, gateway), FX_SOUND: "0" }, timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests[1]!.body).toContain("FX_WRAPPED_HELPER_OK fxwrapped install");
    expect(gateway.requests[1]!.body).not.toContain("command not found");
    // The capture is the only full startup, so the command ran from the snapshot.
    expect(startupLoads(root.home)).toBe(1);
    expect(result.stderr).not.toContain("shell snapshot unavailable");
  }, TIMEOUT);

  test("a user-profile command with a quoting error carries rewrite guidance", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      userShellRun("unmatched", "echo \"oops"),
      fakeGatewayFinalText("Guidance checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Check the guidance."],
      { cwd: root.workspace, env: { ...gatewayEnv(root.home, gateway), FX_SOUND: "0" }, timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    // The snapshot runs the command through eval, so each shell reports the
    // error under `eval` instead of under its own name; see shell-eval-error.ts.
    expect(result.stderr).not.toContain("shell snapshot unavailable");
    expect(gateway.requests[1]!.body).toMatch(EVAL_ERROR_PREFIX);
    expect(gateway.requests[1]!.body).toContain("The shell could not parse this command");
  }, TIMEOUT);

  test("startup files the snapshot cannot capture fall back with one notice", async () => {
    const root = createRoot();
    // A 9 MB alias exceeds the 8 MiB capture limit, while full startup still
    // works for every command.
    writeStartupFiles(
      root.home,
      "printf 'loaded\\n' >> \"$HOME/rc.log\"\n" +
        "alias fxbig=\"$(head -c 9000000 /dev/zero | tr '\\0' x)\"\n" +
        "alias fxsmall='printf FX_FULL_STARTUP_ALIAS'\n",
    );
    const gateway = startFakeGateway([
      userShellRun("first", "fxsmall"),
      userShellRun("second", "fxsmall"),
      fakeGatewayFinalText("Fallback checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Check the fallback."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const notice = "shell snapshot unavailable (the captured state exceeded 8 MiB)";
    expect(occurrences(result.stderr, `fx ask: warning: ${notice}`)).toBe(1);
    expect(occurrences(gateway.requests[1]!.body, notice)).toBe(1);
    // The later request repeats the history, so one notice in total.
    expect(occurrences(gateway.requests[2]!.body, notice)).toBe(1);
    expect(occurrences(gateway.requests[2]!.body, "FX_FULL_STARTUP_ALIAS")).toBe(2);
    // The failed capture plus one full startup per command.
    expect(startupLoads(root.home)).toBe(3);
  }, TIMEOUT);

  test("a fallback notice still appears when the snapshot recovers in the same run", async () => {
    const root = createRoot();
    // The first startup run, the capture, kills its own shell; later runs work.
    writeStartupFiles(
      root.home,
      "if [ ! -e \"$HOME/fault-fired\" ]; then : > \"$HOME/fault-fired\"; kill -9 $$; fi\n" +
        "alias fxa='printf FX_RECOVERY_ALIAS'\n",
    );
    const gateway = startFakeGateway([
      userShellRun("fallback", "fxa"),
      userShellRun("edit", "printf '# edited\\n' >> ~/.zshrc; printf '# edited\\n' >> ~/.bash_profile"),
      userShellRun("recovered", "fxa"),
      fakeGatewayFinalText("Recovery checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "Check recovery."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(existsSync(join(root.home, "fault-fired"))).toBe(true);
    const notice = "fx ask: warning: shell snapshot unavailable (the login shell exited before reporting its state)";
    expect(occurrences(result.stderr, notice)).toBe(1);
    expect(gateway.requests[3]!.body).toContain("FX_RECOVERY_ALIAS");
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())(
    "exported startup-file secrets stay out of traces, sessions, and trace reports",
    async () => {
      const root = createRoot();
      const secret = `FX_SENTINEL_${crypto.randomUUID()}`;
      writeStartupFiles(root.home, `export FX_E2E_SECRET=${secret}\n`);
      const clipboardBin = join(root.root, "clipboard-bin");
      mkdirSync(clipboardBin);
      writeFileSync(join(clipboardBin, "osascript"), "#!/bin/sh\nexit 1\n");
      chmodSync(join(clipboardBin, "osascript"), 0o755);
      const tracePath = join(root.root, "fx-trace.log");
      const gateway = startFakeGateway([
        userShellRun("secret", "test -n \"$FX_E2E_SECRET\" && printf FX_SECRET_VISIBLE"),
        fakeGatewayFinalText("SECRET_CHECK_DONE"),
      ]);
      gateways.push(gateway);
      const session = await TmuxSession.create({
        cwd: root.workspace,
        width: 110,
        height: 34,
        stderrPath: join(root.root, "stderr.log"),
        env: {
          ...gatewayEnv(root.home, gateway),
          FX_PERMISSION_MODE: "full-access",
          FX_SOUND: "0",
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "core,tool,agent,session",
          PATH: `${clipboardBin}:${process.env.PATH}`,
          TMPDIR: root.root,
        },
      });
      try {
        await session.waitForComposer(TIMEOUT);
        await session.sendText("Check the secret.");
        await session.waitForText("SECRET_CHECK_DONE", TIMEOUT);
        await session.sendText("/trace");
        await session.waitForText("Trace saved at", TIMEOUT);
      } finally {
        await session.kill();
      }

      expect(gateway.requests[1]!.body).toContain("FX_SECRET_VISIBLE");
      const report = readTraceReport(latestTraceReportPath(root.root));
      expect(report.all("tool_call").map((call) => call.name)).toContain("shell");
      expect(report.text).not.toContain(secret);
      expect(readFileSync(tracePath, "utf8")).toContain("shell snapshot ready");
      expect(readFileSync(tracePath, "utf8")).not.toContain(secret);
      expect(filesContaining(join(root.home, ".fx"), secret)).toEqual([]);
      for (const request of gateway.requests) expect(request.body).not.toContain(secret);
    },
    TIMEOUT,
  );
});

describe("fx ask with experimental.bash_tool", () => {
  // Fx's built-in tools that the bash tool set replaces. None may reach the model.
  const REPLACED_TOOLS = [
    "shell",
    "read_file",
    "glob_files",
    "grep_files",
    "edit_file",
    "write_file",
    "web_fetch",
    "web_search",
    "exa_search",
    "ask_user_question",
    "install_skill",
    "read_tool_result",
  ];
  const BASH_SETTING = ["--config", "experimental.bash_tool=true"];

  test("offers the bash tool set in place of fx's other built-in tools", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([fakeGatewayFinalText("Tools listed.\n")]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "List the tools."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const names = requestToolNames(gateway.requests[0]!.body);
    expect(names).toEqual(["bash", "toolbox", "vision"]);
    for (const name of REPLACED_TOOLS) expect(names).not.toContain(name);
  }, TIMEOUT);

  test("a bash variable carries from one program to the next", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-set", "bash", { command: "x=41" }),
      fakeGatewayToolCall("bash-add", "bash", { command: "echo $((x+1))" }),
      fakeGatewayFinalText("State carried over.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Carry a variable."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout) as {
      output: string;
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.output).toBe("State carried over.\n");
    expect(output.tool_calls.map(({ name, status }) => ({ name, status }))).toEqual([
      { name: "bash", status: "success" },
      { name: "bash", status: "success" },
    ]);
    expect(gateway.requests).toHaveLength(3);
    expect(toolResultText(gateway.requests[2]!.body, "bash-add")).toContain("42");
  }, TIMEOUT);

  test("FX_OUT names a private results folder under the profile for a saved ask", async () => {
    const root = createRoot();
    const command = 'echo "$FX_OUT"; test -d "$FX_OUT" && echo isdir';
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-out", "bash", { command }),
      fakeGatewayFinalText("Printed.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", ...BASH_SETTING, "Show FX_OUT."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    const text = toolResultText(gateway.requests[1]!.body, "bash-out");
    const results = join(root.home, ".fx", "results");
    expect(text).toContain(`${results}/`);
    expect(text).toContain("isdir");
    expect(existsSync(results)).toBe(true);
  }, TIMEOUT);

  test("with --no-save, FX_OUT is out/ in the bash session folder, and no results folder is made", async () => {
    const root = createRoot();
    const command = 'echo "$FX_OUT"; test -d "$FX_OUT" && echo isdir';
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-out", "bash", { command }),
      fakeGatewayFinalText("Printed.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Show FX_OUT."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    const text = toolResultText(gateway.requests[1]!.body, "bash-out");
    expect(text).toMatch(/\/fx-bash-\d+-[0-9a-f]{16}\/out/);
    expect(text).toContain("isdir");
    expect(existsSync(join(root.home, ".fx", "results"))).toBe(false);
  }, TIMEOUT);

  test("a saved ask that runs no bash program makes no results folder", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([fakeGatewayFinalText("No tools.\n")]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", ...BASH_SETTING, "Say hello."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    expect(existsSync(join(root.home, ".fx", "results"))).toBe(false);
  }, TIMEOUT);

  test("the shell tool gets no FX_OUT", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell-out", "shell", {
        request: { action: "run", command: 'echo "[$FX_OUT]"', yield_time_ms: 30_000 },
      }),
      fakeGatewayFinalText("Printed.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Show FX_OUT."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    expect(toolResultText(gateway.requests[1]!.body, "shell-out")).toContain("[]");
    expect(existsSync(join(root.home, ".fx", "results"))).toBe(false);
  }, TIMEOUT);

  test("a bash state over the size cap is not saved, and the result says so", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-set", "bash", { command: "x=1" }),
      fakeGatewayToolCall("bash-big", "bash", { command: "big=$(head -c 1100000 /dev/zero | tr '\\0' a); echo set" }),
      fakeGatewayToolCall("bash-read", "bash", { command: "echo \"x=$x big=${#big}\"" }),
      fakeGatewayFinalText("Cap checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Save a large state."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(toolResultText(gateway.requests[2]!.body, "bash-big")).toContain("over the 1048576-byte limit");
    expect(toolResultText(gateway.requests[3]!.body, "bash-read")).toContain("x=1 big=0");
  }, TIMEOUT);

  test("edit changes a file from a heredoc, and the result names the counts", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-edit", "bash", {
        command: "edit app.py <<'EOF'\n<<<<<<< SEARCH\nprint('a')\n=======\nprint('b')\n>>>>>>> REPLACE\nEOF",
      }),
      fakeGatewayFinalText("Edited.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Change the print."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('b')\n");
    expect(toolResultText(gateway.requests[1]!.body, "bash-edit")).toContain("edited app.py +1 -1");
  }, TIMEOUT);

  test("write creates a file from stdin, and the result names it", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-write", "bash", {
        command: "write new.txt <<'EOF'\nhello\nEOF",
      }),
      fakeGatewayFinalText("Written.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Create the file."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(join(root.workspace, "new.txt"), "utf8")).toBe("hello\n");
    expect(toolResultText(gateway.requests[1]!.body, "bash-write")).toContain("wrote new.txt +1");
  }, TIMEOUT);

  test("a malformed edit shows its line, and changes nothing", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-bad", "bash", {
        command: "edit app.py <<'EOF'\n<<<<<<< SEARCH\nprint('a')\nprint('b')\nEOF",
      }),
      fakeGatewayFinalText("Refused.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Change the print."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('a')\n");
    expect(toolResultText(gateway.requests[1]!.body, "bash-bad")).toContain("fx tool edit: line 1: ");
  }, TIMEOUT);

  test("fx tool run outside a program fx started exits 3 and changes nothing", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");

    const result = await runFx(["tool", "edit", "app.py"], {
      cwd: root.workspace,
      env: { FX_MCP_CALL_SOCKET: undefined, FX_MCP_CALL_TOKEN: undefined },
      stdin: "<<<<<<< SEARCH\nprint('a')\n=======\nprint('b')\n>>>>>>> REPLACE\n",
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(3);
    expect(result.stderr).toContain(
      "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, while that program runs.",
    );
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('a')\n");
  }, TIMEOUT);

  test("a bash state over the size cap that the program ends with exit is reported, and the old value stays", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-set", "bash", { command: "x=1" }),
      fakeGatewayToolCall("bash-exit", "bash", { command: "x=2; big=$(head -c 1100000 /dev/zero | tr '\\0' a); exit 0" }),
      fakeGatewayToolCall("bash-read", "bash", { command: "echo \"x=$x big=${#big}\"" }),
      fakeGatewayFinalText("Exit checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Save a large state, then exit."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(toolResultText(gateway.requests[2]!.body, "bash-exit")).toContain("over the 1048576-byte limit, so it was not saved");
    expect(toolResultText(gateway.requests[3]!.body, "bash-read")).toContain("x=1 big=0");
  }, TIMEOUT);

  test("the working folder carries from one program to the next", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-cd", "bash", { command: "mkdir -p sub && cd sub" }),
      fakeGatewayToolCall("bash-pwd", "bash", { command: "pwd" }),
      fakeGatewayFinalText("Folder carried over.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Change folder."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(toolResultText(gateway.requests[2]!.body, "bash-pwd")).toContain(`${root.workspace}/sub`);
  }, TIMEOUT);

  test("in auto mode the review sees the folder a bash program starts in", async () => {
    const root = createRoot();
    const gateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-cd", "bash", { command: "mkdir -p sub && cd sub" }),
        fakeGatewayToolCall("bash-touch", "bash", { command: "touch made" }),
        fakeGatewayFinalText("Review saw the folder.\n"),
      ],
      { classifierResponses: [fakeGatewayPermissionDecision(), fakeGatewayPermissionDecision()] },
    );
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Make a file in a folder."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const touchReview = gateway.classifierRequests.find(({ body }) => body.includes("touch made"));
    expect(touchReview).toBeDefined();
    expect(touchReview!.body).toContain(`${root.workspace}/sub`);
    expect(existsSync(join(root.workspace, "sub", "made"))).toBe(true);
  }, TIMEOUT);

  test("in auto mode a bash program is reviewed even when a saved function would make its command routine", async () => {
    const root = createRoot();
    const gateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-define", "bash", { command: "git() { echo SAVED-GIT-RAN; }" }),
        fakeGatewayToolCall("bash-git", "bash", { command: "git status --short" }),
        fakeGatewayFinalText("Saved function reviewed.\n"),
      ],
      { classifierResponses: [fakeGatewayPermissionDecision(), fakeGatewayPermissionDecision()] },
    );
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Define git and run it."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(gateway.classifierRequests).toHaveLength(2);
    expect(gateway.classifierRequests.some(({ body }) => body.includes("git status --short"))).toBe(true);
    expect(toolResultText(gateway.requests[2]!.body, "bash-git")).toContain("SAVED-GIT-RAN");
  }, TIMEOUT);

  test("in auto mode a bash program's alias for a name the startup files define carries to the next program", async () => {
    const root = createRoot();
    writeFileSync(join(root.home, ".bash_profile"), "alias ll='echo RC-LL'\n");
    const gateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-set", "bash", { command: "alias ll='echo MINE-LL'" }),
        fakeGatewayToolCall("bash-ll", "bash", { command: "ll" }),
        fakeGatewayFinalText("Alias carried.\n"),
      ],
      { classifierResponses: [fakeGatewayPermissionDecision(), fakeGatewayPermissionDecision()] },
    );
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Define ll and run it."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const ll = toolResultText(gateway.requests[2]!.body, "bash-ll");
    expect(ll).toContain("MINE-LL");
    expect(ll).not.toContain("RC-LL");
  }, TIMEOUT);

  test("wait_more with nothing running says so", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-wait", "bash", { command: "wait_more" }),
      fakeGatewayFinalText("Waited.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Wait for it."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(toolResultText(gateway.requests[1]!.body, "bash-wait")).toContain("Nothing is running.");
  }, TIMEOUT);

  test("in auto mode a program gets one review and a wait gets none", async () => {
    const root = createRoot();
    const gateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-echo", "bash", { command: "echo hi" }),
        fakeGatewayToolCall("bash-wait", "bash", { command: "wait_more" }),
        fakeGatewayFinalText("Review counted.\n"),
      ],
      { classifierResponses: [fakeGatewayPermissionDecision()] },
    );
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Run a program and wait."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(gateway.classifierRequests).toHaveLength(1);
    expect(gateway.classifierRequests[0]!.body).toContain("echo hi");
    expect(toolResultText(gateway.requests[1]!.body, "bash-echo")).toContain("hi");
    expect(toolResultText(gateway.requests[2]!.body, "bash-wait")).toContain("Nothing is running.");
  }, TIMEOUT);

  test("without the setting the same run offers shell and not bash", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([fakeGatewayFinalText("Tools listed.\n")]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", "List the tools."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const names = requestToolNames(gateway.requests[0]!.body);
    expect(names).toContain("shell");
    expect(names).not.toContain("bash");
  }, TIMEOUT);

  test("a model-sent action does not change what bash does", async () => {
    const root = createRoot();
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-wait-sent-action", "bash", { command: "wait_more", action: "run" }),
      fakeGatewayFinalText("Waited.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Wait for it."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout) as {
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.tool_calls.map(({ name, status }) => ({ name, status }))).toEqual([
      { name: "bash", status: "success" },
    ]);
    const waitResult = toolResultText(gateway.requests[1]!.body, "bash-wait-sent-action");
    expect(waitResult).toContain("Nothing is running.");
    expect(waitResult).not.toContain("send wait_more");
    expect(gateway.classifierRequests).toHaveLength(0);
  }, TIMEOUT);

  test("2a: outside-workspace paths (../x and /tmp/x) are denied in fx ask without a prompter and reviewed in auto mode", async () => {
    const root = createRoot();
    const relTarget = join(root.root, "outside-rel.txt");
    const absDir = mkdtempSync(join(tmpdir(), "fx-bash-outside-"));
    roots.push(absDir);
    const absTarget = join(absDir, "outside-abs.txt");
    writeFileSync(relTarget, "orig-rel\n");

    mkdirSync(join(root.home, ".fx"), { recursive: true });
    writeFileSync(
      join(root.home, ".fx", "settings.json"),
      JSON.stringify({ permission: { bash: "allow" } }) + "\n",
    );
    writeFileSync(
      join(root.workspace, "run-rel.sh"),
      "edit ../outside-rel.txt <<'EOF'\n<<<<<<< SEARCH\norig-rel\n=======\nhacked-rel\n>>>>>>> REPLACE\nEOF\necho \"rel_exit=$?\"\n",
    );
    writeFileSync(
      join(root.workspace, "run-abs.sh"),
      `write "${absTarget}" <<'EOF'\nhacked-abs\nEOF\necho "abs_exit=$?"\n`,
    );

    const denyGateway = startFakeGateway([
      fakeGatewayToolCall("bash-out-rel", "bash", { command: ". ./run-rel.sh" }),
      fakeGatewayToolCall("bash-out-abs", "bash", { command: ". ./run-abs.sh" }),
      fakeGatewayFinalText("Denied.\n"),
    ]);
    gateways.push(denyGateway);

    const denyResult = await runFx(
      ["ask", "--json", "--ask", "--no-save", ...BASH_SETTING, "Touch outside files."],
      { cwd: root.workspace, env: { ...gatewayEnv(root.home, denyGateway), FX_PERMISSION_MODE: "ask" }, timeoutMs: TIMEOUT },
    );
    expect(denyResult.code).toBe(0);
    expect(readFileSync(relTarget, "utf8")).toBe("orig-rel\n");
    expect(existsSync(absTarget)).toBe(false);
    const relOut = toolResultText(denyGateway.requests[1]!.body, "bash-out-rel");
    const absOut = toolResultText(denyGateway.requests[2]!.body, "bash-out-abs");
    expect(relOut).toContain("rel_exit=5");
    expect(relOut).toContain("fx tool edit:");
    expect(absOut).toContain("abs_exit=5");
    expect(absOut).toContain("fx tool write:");

    const cautionGateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-auto-caution", "bash", { command: ". ./run-rel.sh" }),
        fakeGatewayFinalText("Caution held.\n"),
      ],
      {
        classifierResponses: [
          fakeGatewayToolCall("permission_decision_1", "permission_decision", {
            risk: "high",
            decision: "caution",
            category: "system_harm",
            evidence: relTarget,
            rationale: "outside workspace",
          }),
          fakeGatewayToolCall("permission_decision_2", "permission_decision", {
            risk: "high",
            decision: "caution",
            category: "system_harm",
            evidence: relTarget,
            rationale: "outside workspace",
          }),
        ],
      },
    );
    gateways.push(cautionGateway);

    const cautionResult = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Edit outside in auto mode."],
      { cwd: root.workspace, env: gatewayEnv(root.home, cautionGateway), timeoutMs: TIMEOUT },
    );
    expect(cautionResult.code).toBe(0);
    expect(readFileSync(relTarget, "utf8")).toBe("orig-rel\n");
    expect(cautionGateway.classifierRequests.length).toBeGreaterThanOrEqual(1);
    const reviewBody = cautionGateway.classifierRequests[0]!.body;
    expect(reviewBody).toContain(relTarget);

    const clearGateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-auto-clear", "bash", {
          command: "edit ../outside-rel.txt <<'EOF'\n<<<<<<< SEARCH\norig-rel\n=======\nallowed-rel\n>>>>>>> REPLACE\nEOF\necho \"exit=$?\"",
        }),
        fakeGatewayFinalText("Allowed.\n"),
      ],
      { classifierResponses: [fakeGatewayPermissionDecision()] },
    );
    gateways.push(clearGateway);

    const clearResult = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Edit outside with clear."],
      { cwd: root.workspace, env: gatewayEnv(root.home, clearGateway), timeoutMs: TIMEOUT },
    );
    expect(clearResult.code).toBe(0);
    expect(readFileSync(relTarget, "utf8")).toBe("allowed-rel\n");
    expect(toolResultText(clearGateway.requests[1]!.body, "bash-auto-clear")).toContain("exit=0");
  }, TIMEOUT);

  test("2b: a workspace symlink pointing outside is resolved to its canonical path like edit_file", async () => {
    const root = createRoot();
    const outsideDir = join(root.root, "outside-dir");
    mkdirSync(outsideDir);
    const outsideFile = join(outsideDir, "outside-target.txt");
    writeFileSync(outsideFile, "before\n");
    symlinkSync(outsideFile, join(root.workspace, "link.txt"));
    symlinkSync(outsideDir, join(root.workspace, "dir-link"));

    mkdirSync(join(root.home, ".fx"), { recursive: true });
    writeFileSync(
      join(root.home, ".fx", "settings.json"),
      JSON.stringify({ permission: { bash: "allow" } }) + "\n",
    );
    writeFileSync(
      join(root.workspace, "run-sym-file.sh"),
      "edit link.txt <<'EOF'\n<<<<<<< SEARCH\nbefore\n=======\nafter\n>>>>>>> REPLACE\nEOF\necho \"file_exit=$?\"\n",
    );
    writeFileSync(
      join(root.workspace, "run-sym-dir.sh"),
      "edit dir-link/outside-target.txt <<'EOF'\n<<<<<<< SEARCH\nbefore\n=======\nafter\n>>>>>>> REPLACE\nEOF\necho \"dir_exit=$?\"\n",
    );

    const askGateway = startFakeGateway([
      fakeGatewayToolCall("bash-sym-file", "bash", { command: ". ./run-sym-file.sh" }),
      fakeGatewayToolCall("bash-sym-dir", "bash", { command: ". ./run-sym-dir.sh" }),
      fakeGatewayFinalText("Denied symlink.\n"),
    ]);
    gateways.push(askGateway);

    const askRes = await runFx(
      ["ask", "--json", "--ask", "--no-save", ...BASH_SETTING, "Edit symlink."],
      { cwd: root.workspace, env: { ...gatewayEnv(root.home, askGateway), FX_PERMISSION_MODE: "ask" }, timeoutMs: TIMEOUT },
    );
    expect(askRes.code).toBe(0);
    expect(readFileSync(outsideFile, "utf8")).toBe("before\n");
    // Symlink file target is rejected as not a regular file (same as edit_file).
    const symFileOut = toolResultText(askGateway.requests[1]!.body, "bash-sym-file");
    expect(symFileOut).toContain("target is not a regular file");
    expect(symFileOut).toContain("file_exit=6");
    // Symlink directory target fails traversal check as path_outside_workspace (same as edit_file).
    const symDirOut = toolResultText(askGateway.requests[2]!.body, "bash-sym-dir");
    expect(symDirOut).toContain("path_outside_workspace");
    expect(symDirOut).toContain("dir_exit=6");

    const autoGateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-sym-auto", "bash", { command: ". ./run-sym-file.sh" }),
        fakeGatewayFinalText("Refused symlink in auto mode.\n"),
      ],
    );
    gateways.push(autoGateway);

    const autoRes = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Edit symlink in auto mode."],
      { cwd: root.workspace, env: gatewayEnv(root.home, autoGateway), timeoutMs: TIMEOUT },
    );
    expect(autoRes.code).toBe(0);
    expect(autoGateway.classifierRequests).toHaveLength(0);
    expect(readFileSync(outsideFile, "utf8")).toBe("before\n");
    expect(toolResultText(autoGateway.requests[1]!.body, "bash-sym-auto")).toContain("target is not a regular file");
  }, TIMEOUT);

  test("2c: 65 blocks exits 2 with the at-most-64-blocks line message and sends nothing", async () => {
    const root = createRoot();
    const tracePath = join(root.root, "trace-65.log");
    const lines = Array.from({ length: 65 }, (_, i) => `line-${i + 1}`);
    writeFileSync(join(root.workspace, "app.py"), `${lines.join("\n")}\n`);
    const blocks = lines
      .map((line, i) => `<<<<<<< SEARCH\n${line}\n=======\nupdated-${i + 1}\n>>>>>>> REPLACE`)
      .join("\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-65", "bash", {
        command: `edit app.py <<'EOF'\n${blocks}\nEOF\necho "exit=$?"`,
      }),
      fakeGatewayFinalText("Refused 65 blocks.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Send 65 blocks."],
      {
        cwd: root.workspace,
        env: {
          ...gatewayEnv(root.home, gateway),
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "mcp-call",
        },
        timeoutMs: TIMEOUT,
      },
    );

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-65");
    expect(shown).toContain("exit=2");
    expect(shown).toContain("fx tool edit: line 321: an edit takes at most 64 blocks");
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe(`${lines.join("\n")}\n`);
    const trace = readFileSync(tracePath, "utf8");
    expect(trace).not.toContain("bridge refused");
    expect(trace).not.toContain("request=");
  }, TIMEOUT);

  test("2d: a write larger than the request limit exits 2 with the split message", async () => {
    const root = createRoot();
    const target = join(root.workspace, "big.txt");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-over-stdin", "bash", {
        command: "head -c 1048577 /dev/zero | tr '\\0' a | write big.txt; echo \"over_exit=$?\"",
      }),
      fakeGatewayFinalText("Too big.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Write over limit."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-over-stdin");
    expect(shown).toContain("over_exit=2");
    expect(shown).toContain("fx tool write: the change on stdin is larger than 1048576 bytes. Split the change into several smaller calls.");
    expect(existsSync(target)).toBe(false);
  }, TIMEOUT);

  test("2d-edge: a write under stdin limit whose JSON wire request exceeds 1 MiB exits 2 without ConnectionLost", async () => {
    const root = createRoot();
    const target = join(root.workspace, "exact1m.txt");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-exact-1m", "bash", {
        command: "head -c 1048576 /dev/zero | tr '\\0' a | write exact1m.txt; echo \"exact_exit=$?\"",
      }),
      fakeGatewayFinalText("Checked exact 1 MiB.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Write exact 1 MiB."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-exact-1m");
    expect(existsSync(target)).toBe(false);
    expect(shown).toContain("exact_exit=2");
  }, TIMEOUT);

  test("2d-encoded: 700000 quotes under stdin limit exceeds encoded wire limit, exits 2 with split message, and creates nothing", async () => {
    const root = createRoot();
    const target = join(root.workspace, "quotes.txt");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-quotes-over", "bash", {
        command: 'head -c 700000 /dev/zero | tr \'\\0\' \'"\' | write quotes.txt; echo "quotes_exit=$?"',
      }),
      fakeGatewayFinalText("Encoded too big.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Write 700000 quotes."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-quotes-over");
    expect(shown).toContain("quotes_exit=2");
    expect(shown).toContain("encoded");
    expect(shown).toContain("1048576 bytes. Split the change into several smaller calls.");
    expect(existsSync(target)).toBe(false);
  }, TIMEOUT);

  test("finding 3: cd sub && edit app.py changes sub/app.py and edit ../app.py from sub changes root app.py", async () => {
    const root = createRoot();
    mkdirSync(join(root.workspace, "sub"), { recursive: true });
    writeFileSync(join(root.workspace, "app.py"), "root-before\n");
    writeFileSync(join(root.workspace, "sub", "app.py"), "sub-before\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-cd-sub", "bash", {
        command: [
          "cd sub && edit app.py <<'EOF'",
          "<<<<<<< SEARCH",
          "sub-before",
          "=======",
          "sub-after",
          ">>>>>>> REPLACE",
          "EOF",
          "edit ../app.py <<'EOF'",
          "<<<<<<< SEARCH",
          "root-before",
          "=======",
          "root-after",
          ">>>>>>> REPLACE",
          "EOF",
        ].join("\n"),
      }),
      fakeGatewayFinalText("Cwd edits done.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Edit in sub and parent."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(join(root.workspace, "sub", "app.py"), "utf8")).toBe("sub-after\n");
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("root-after\n");
    const shown = toolResultText(gateway.requests[1]!.body, "bash-cd-sub");
    expect(shown).toContain("edited sub/app.py +1 -1");
    expect(shown).toContain("edited app.py +1 -1");
  }, TIMEOUT);

  test("exported edit and write work inside a bash -c child process and do not leak into saved state", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-child-edit", "bash", {
        command: [
          "bash -c \"edit app.py <<'EOF'",
          "<<<<<<< SEARCH",
          "print('a')",
          "=======",
          "print('child')",
          ">>>>>>> REPLACE",
          "EOF\"",
          "bash -c \"write child.txt <<'EOF'",
          "from-child",
          "EOF\"",
          "saved_ok=1",
        ].join("\n"),
      }),
      fakeGatewayToolCall("bash-after-child", "bash", {
        command: "echo \"saved_ok=$saved_ok\"; declare -f edit write >/dev/null && echo funcs=yes || echo funcs=no",
      }),
      fakeGatewayFinalText("Child bash done.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Run edit and write in bash -c."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('child')\n");
    expect(readFileSync(join(root.workspace, "child.txt"), "utf8")).toBe("from-child\n");
    const childResult = toolResultText(gateway.requests[1]!.body, "bash-child-edit");
    expect(childResult).toContain("edited app.py +1 -1");
    expect(childResult).toContain("wrote child.txt +1");
    const nextResult = toolResultText(gateway.requests[2]!.body, "bash-after-child");
    expect(nextResult).toContain("saved_ok=1");
    expect(nextResult).toContain("funcs=yes");
  }, TIMEOUT);

  test("2h: a CRLF file with LF search text is not found with closest-lines hint and writes nothing", async () => {
    const root = createRoot();
    const target = join(root.workspace, "crlf.txt");
    writeFileSync(target, "alpha\r\nbeta\r\ngamma\r\n");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-crlf", "bash", {
        command: "edit crlf.txt <<'EOF'\n<<<<<<< SEARCH\nalpha\nbeta\n=======\nALPHA\nBETA\n>>>>>>> REPLACE\nEOF\necho \"exit=$?\"",
      }),
      fakeGatewayFinalText("CRLF refused.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Edit CRLF with LF."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-crlf");
    expect(shown).toContain("exit=6");
    expect(shown).toContain("not found in file; the closest match is lines 1-2");
    expect(readFileSync(target, "utf8")).toBe("alpha\r\nbeta\r\ngamma\r\n");
  }, TIMEOUT);

  test("2i: path with spaces and non-ASCII, empty write, and overwrite of existing file reviewed as write", async () => {
    const root = createRoot();
    const spacedName = "my dir/café naïve.txt";
    const spacedPath = join(root.workspace, spacedName);
    const emptyPath = join(root.workspace, "empty.txt");
    const existingPath = join(root.workspace, "existing.txt");
    const externalExistingPath = join(root.root, "external-existing.txt");
    writeFileSync(existingPath, "old1\nold2\n");
    writeFileSync(externalExistingPath, "ext1\next2\n");

    const gateway = startFakeGateway(
      [
        fakeGatewayToolCall("bash-2i", "bash", {
          command: [
            `write "${spacedName}" <<'EOF'`,
            "hello café",
            "EOF",
            `edit "${spacedName}" <<'EOF'`,
            "<<<<<<< SEARCH",
            "hello café",
            "=======",
            "bonjour café",
            ">>>>>>> REPLACE",
            "EOF",
            "write empty.txt </dev/null",
            "echo \"empty_exit=$?\"",
            "write existing.txt <<'EOF'",
            "new1",
            "EOF",
            "echo \"overwrite_exit=$?\"",
            "write ../external-existing.txt <<'EOF'",
            "ext-new1",
            "EOF",
            "echo \"ext_overwrite_exit=$?\"",
          ].join("\n"),
        }),
        fakeGatewayFinalText("All 2i done.\n"),
      ],
      {
        classifierResponses: [
          fakeGatewayPermissionDecision(),
          fakeGatewayPermissionDecision(),
        ],
      },
    );
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", ...BASH_SETTING, "Run 2i cases."],
      { cwd: root.workspace, env: gatewayEnv(root.home, gateway), timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(readFileSync(spacedPath, "utf8")).toBe("bonjour café\n");
    expect(existsSync(emptyPath)).toBe(true);
    expect(readFileSync(emptyPath, "utf8")).toBe("");
    expect(readFileSync(existingPath, "utf8")).toBe("new1\n");
    expect(readFileSync(externalExistingPath, "utf8")).toBe("ext-new1\n");

    const shown = toolResultText(gateway.requests[1]!.body, "bash-2i");
    expect(shown).toContain(`wrote ${spacedName} +1`);
    expect(shown).toContain(`edited ${spacedName} +1 -1`);
    expect(shown).toContain("empty_exit=0");
    expect(shown).toContain("wrote existing.txt +1 -2");
    expect(shown).toContain("overwrite_exit=0");
    expect(shown).toContain(`wrote ${externalExistingPath} +1 -2`);
    expect(shown).toContain("ext_overwrite_exit=0");

    // Overwriting an external existing file goes through the write_file review path with preimage present.
    const writeReview = gateway.classifierRequests.find(
      ({ body }) => body.includes("action: prepared_file_mutation") && body.includes("external-existing.txt"),
    );
    expect(writeReview).toBeDefined();
    expect(writeReview!.body).toContain("preimage: present");
    expect(writeReview!.body).toContain("additions: 1");
    expect(writeReview!.body).toContain("deletions: 2");
  }, TIMEOUT);
});

describe("fx tool and fx mcp call without MCP servers", () => {
  const BASH_SETTING = ["--config", "experimental.bash_tool=true"];

  test("the shell tool starts no bridge, and fx mcp call exits 3 as it does outside fx", async () => {
    const root = createRoot();
    const command =
      'echo "socket=[$FX_MCP_CALL_SOCKET] token=[$FX_MCP_CALL_TOKEN]"; "' + FX_BIN + '" mcp call list fixture; echo "exit=$?"';
    const gateway = startFakeGateway([
      fakeGatewayToolCall("run_call", "shell", { action: "run", command }),
      fakeGatewayFinalText("Checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Check the bridge."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "run_call");
    expect(shown).toContain("socket=[] token=[]");
    expect(shown).toContain("no running fx shell call to reach");
    expect(shown).toContain("exit=3");
  }, TIMEOUT);

  test("the bash tool without MCP servers: fx mcp call says MCP is not available, and fx tool still edits", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");
    const command =
      '"' + FX_BIN + '" mcp call list fixture; echo "exit=$?"; edit app.py <<\'EOF\'\n<<<<<<< SEARCH\nprint(\'a\')\n=======\nprint(\'b\')\n>>>>>>> REPLACE\nEOF';
    const gateway = startFakeGateway([
      fakeGatewayToolCall("bash-both", "bash", { command }),
      fakeGatewayFinalText("Done.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", ...BASH_SETTING, "Read and edit."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "bash-both");
    expect(shown).toContain("fx mcp call: MCP is not available in this session.");
    expect(shown).toContain("exit=1");
    expect(shown).toContain("edited app.py +1 -1");
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('b')\n");
  }, TIMEOUT);

  test("2j: the shell tool with no MCP servers has no bridge env at all and fx tool edit exits 3", async () => {
    const root = createRoot();
    writeFileSync(join(root.workspace, "app.py"), "print('a')\n");
    const command =
      'echo "socket=[$FX_MCP_CALL_SOCKET] token=[$FX_MCP_CALL_TOKEN]"; "' +
      FX_BIN +
      '" tool edit app.py <<\'EOF\'\n<<<<<<< SEARCH\nprint(\'a\')\n=======\nprint(\'b\')\n>>>>>>> REPLACE\nEOF\necho "exit=$?"';
    const gateway = startFakeGateway([
      fakeGatewayToolCall("run_tool_edit", "shell", { action: "run", command }),
      fakeGatewayFinalText("Checked.\n"),
    ]);
    gateways.push(gateway);

    const result = await runFx(["ask", "--json", "--yolo", "--no-save", "Check fx tool edit without MCP."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, gateway),
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(0);
    const shown = toolResultText(gateway.requests[1]!.body, "run_tool_edit");
    expect(shown).toContain("socket=[] token=[]");
    expect(shown).toContain("exit=3");
    expect(shown).toContain(
      "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, while that program runs.",
    );
    expect(readFileSync(join(root.workspace, "app.py"), "utf8")).toBe("print('a')\n");
  }, TIMEOUT);
});
