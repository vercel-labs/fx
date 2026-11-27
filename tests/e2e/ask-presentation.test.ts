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
  watch,
  writeFileSync,
} from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { latestTraceReportPath, readTraceReport } from "./trace-report";
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
  heldFakeGatewayFinalText,
  startDynamicFakeGateway,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
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
  for (const watcher of openOutputWatchers.splice(0)) watcher.close();
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

function terminalCommand(args: string[], stdinFrom?: string): string {
  const fx = [FX_BIN, ...args].map(shellQuote).join(" ");
  const redirect = stdinFrom === undefined ? "" : ` < ${shellQuote(stdinFrom)}`;
  const script = `${fx}${redirect}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
  return `/bin/sh -c ${shellQuote(script)}`;
}

const MCP_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const MCP_TOOL = "mcp_fixture_echo";
const MCP_MODEL = "openai/gpt-5";
const MCP_TIMEOUT = 60_000;

/** A profile whose MCP fixture asks one form, with `field` as its only question. */
function writeMcpFormProfile(root: { root: string; home: string }, field: Record<string, unknown>): void {
  mkdirSync(join(root.home, ".fx"), { recursive: true });
  writeFileSync(
    join(root.home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, MCP_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_WIRE_LOG: join(root.root, "mcp-wire.jsonl"),
            FX_MCP_PID_PATH: join(root.root, "mcp.pid"),
            FX_MCP_MODE: "mrtr_input_required",
            FX_MCP_COMPACT_FIELD: JSON.stringify(field),
          },
        },
      },
    }),
  );
}

function directCommand(args: string[]): string {
  return [FX_BIN, ...args].map(shellQuote).join(" ");
}

const openOutputWatchers: Array<ReturnType<typeof watch>> = [];

/**
 * Resolves with the raw pane output once it holds `needle`. The pipe copies the
 * output to the file asynchronously, so each write to the folder checks the file
 * again. The test's own timeout ends a wait that never sees `needle`; afterEach
 * closes any watcher still open.
 */
function readOutputUntil(path: string, needle: string): Promise<string> {
  return new Promise((resolve) => {
    let watcher: ReturnType<typeof watch> | undefined;
    const check = (): void => {
      const text = existsSync(path) ? readFileSync(path, "utf8") : "";
      if (!text.includes(needle)) return;
      watcher?.close();
      resolve(text);
    };
    watcher = watch(dirname(path), check);
    openOutputWatchers.push(watcher);
    check();
  });
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

/** A profile whose MCP fixture asks for one form field with the given schema. */
function createMcpFormRoot(field: Record<string, unknown>) {
  const root = createRoot();
  mkdirSync(join(root.home, ".fx"), { recursive: true });
  writeFileSync(join(root.home, ".fx", "settings.json"), JSON.stringify({}));
  writeFileSync(
    join(root.home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, MCP_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_WIRE_LOG: join(root.root, "mcp-wire.jsonl"),
            FX_MCP_PID_PATH: join(root.root, "mcp.pid"),
            FX_MCP_MODE: "mrtr_input_required",
            FX_MCP_EXPECT_ELICITATION: "both",
            FX_MCP_COMPACT_FIELD: JSON.stringify(field),
          },
        },
      },
    }),
  );
  return root;
}

function mcpFormEnv(home: string, gateway: ReturnType<typeof startFakeGateway>) {
  return { ...gatewayEnv(home, gateway), FX_MODEL: MCP_MODEL, NO_COLOR: undefined };
}

/** Real permission prompts: the settings file picks "ask", so the env must not override it. */
function permissionAskEnv(home: string, gateway: ReturnType<typeof startFakeGateway>) {
  return { ...gatewayEnv(home, gateway), FX_PERMISSION_MODE: undefined, NO_COLOR: undefined };
}

function createAskPermissionRoot() {
  const root = createRoot();
  mkdirSync(join(root.home, ".fx"), { recursive: true });
  writeFileSync(
    join(root.home, ".fx", "settings.json"),
    JSON.stringify({ permission_mode: "ask", sandbox: "none" }),
  );
  return root;
}

/** Whitespace removed, so a sentence that wrapped at any column still matches. */
function withoutWhitespace(text: string): string {
  return text.replace(/\s+/g, "");
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
    "ask in a terminal stream error after a partial line keeps the committed text once",
    async () => {
      const root = createRoot();
      const finalText = "A complete replacement response.";
      const gateway = startFakeGateway([
        fakeGatewaySse([
          { type: "text-delta", id: "answer_1", delta: "Streaming **bold" },
          { type: "finish", finishReason: { unified: "error", raw: "provider_error" } },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateways.push(gateway);
      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Fail mid line."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);
      await session.waitForText(finalText, TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();

      expect(scrollback.split(finalText).length - 1).toBe(1);
      expect(scrollback.split("Streaming **bold").length - 1).toBe(1);
      expect(scrollback).not.toContain("Streaming bold");
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "ask in a terminal Ctrl+C on a partial line commits the held text once and leaves no tail",
    async () => {
      const root = createRoot();
      const held = heldFakeGatewayFinalText();
      const gateway = startFakeGateway([() => held.response]);
      gateways.push(gateway);
      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Cancel mid line."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);
      held.send("Streaming **bold");
      await session.waitForText("Streaming bold", TIMEOUT);
      await session.sendKeys("C-c");
      await session.waitForText("Streaming **bold", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      held.dispose();

      expect(scrollback.split("Streaming **bold").length - 1).toBe(1);
      expect(scrollback).not.toContain("Streaming bold");
    },
    TIMEOUT * 2,
  );

  // tmux's "Pane is dead" row is not fx's output. tmux draws it only once
  // it has the command's exit status, which can come after it marks the
  // pane dead, and on CI it can still be missing when the capture runs.
  // So the rows leave it out, with the blank rows after fx's output. Only
  // the exact row goes, so another row that starts with the same words stays.
  const tmuxDeadPaneRow = /^Pane is dead \(status \d+, [^)]*\)$/;
  // tmux's default `remain-on-exit-format`, the same in tmux 3.4, 3.6 and
  // 3.6a. It draws the rows that `tmuxDeadPaneRow` matches.
  const tmuxDeadPaneFormat =
    "Pane is dead (#{?#{!=:#{pane_dead_status},},status #{pane_dead_status},}" +
    "#{?#{!=:#{pane_dead_signal},},signal #{pane_dead_signal},}, #{t:pane_dead_time})";
  const rowsOf = (text: string) => {
    const rows = text
      .replace(/\b\d+(?:h\d+m\d+s|m\d+s|s)\b/g, "Ns")
      .replace(/↑\d+(?:\.\d+)?k? ↓\d+(?:\.\d+)?k?/g, "↑N ↓N")
      .split("\n")
      .map((row) => row.trimEnd())
      .filter((row) => !tmuxDeadPaneRow.test(row));
    while (rows.length > 0 && rows[rows.length - 1] === "") rows.pop();
    return rows;
  };
  // A run is over once the shell prints its exit marker and tmux marks
  // the pane dead, which it does after it reads the last output. A
  // session that is gone can show no marker, so the wait fails at once
  // then, and it gives up well before the test's own timeout, so a
  // failure shows the pane.
  const waitForExit = async (target: TmuxSession) => {
    await target.waitForPane((pane) => {
      if (pane.includes("__FX_EXIT_0__")) return true;
      if (!target.isAlive()) throw new Error(`${target.name} ended before it showed its exit marker`);
      return false;
    }, 10_000);
    await target.waitForPane(() => target.paneStatus().dead, 10_000);
  };

  test("screen rows leave out only tmux's own Pane is dead row", () => {
    const ownRow = "Pane is dead is a row at column 0 that tmux did not draw.";
    // The rows tmux 3.4 and 3.6a draw when the pane's command exits.
    expect(rowsOf(`${ownRow}\n__FX_EXIT_0__\n\nPane is dead (status 0, Wed Nov 25 21:27:52 2026)\n\n`))
      .toEqual([ownRow, "__FX_EXIT_0__"]);
    expect(rowsOf(`${ownRow}\n__FX_EXIT_3__\n\nPane is dead (status 3, Thu Nov  5 09:07:02 2026)\n`))
      .toEqual([ownRow, "__FX_EXIT_3__"]);
    expect(rowsOf("")).toEqual([]);
    // A row for a pane that a signal ended stays. Each run in these tests
    // exits with status 0 after its exit marker, so a signal row means the run
    // did not end cleanly, and the comparison shows it instead of hiding it.
    const signalRow = "Pane is dead (signal 15, Wed Nov 25 21:27:52 2026)";
    expect(rowsOf(`${ownRow}\n\n${signalRow}\n`)).toEqual([ownRow, "", signalRow]);
  });

  test.skipIf(!tmuxAvailable())(
    "ask in a terminal keeps its own Pane is dead row and drops tmux's in the screen rows",
    async () => {
      const root = createRoot();
      const reply = "Pane is dead is a row fx wrote.";
      const gateway = startFakeGateway([fakeGatewayFinalText(`First row.\n\n${reply}\n`)]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Write the row."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
        stderrPath,
      });
      sessions.push(session);
      await waitForExit(session);
      const rows = rowsOf(await session.captureFullScrollback());

      // fx indents its reply rows by two columns.
      expect(rows).toContain(`  ${reply}`);
      // tmux may not have drawn its row yet, so the format is checked as text.
      // Its expansion would not help: tmux fills in the status and time at the
      // same moment it draws the row.
      expect(session.remainOnExitFormat()).toBe(tmuxDeadPaneFormat);
      // A row tmux did draw matches the pattern, so it is not left.
      expect(rows.filter((row) => row.startsWith("Pane is dead ("))).toEqual([]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "ask in a terminal shows streamed words formatted before their line ends",
    async () => {
      const root = createRoot();
      const prompt = "Stream the formatted reply.";
      const calibration = "Calibration **bold** line.\n\n";
      const streamedLine = "Streaming **bold";
      const streamedRest = " words** and `code` here.\n\n| a | b |";
      const ending = "\n|---|---|\n| 1 | 2 |\n\nDone.\n";
      const fullReply = `${calibration}${streamedLine}${streamedRest}${ending}`;
      const boldSgr = /\x1b\[(?:[0-9;]*;)?1(?:;[0-9;]*)?m/;
      const sgrBeforeBold = (row: string) =>
        row.slice(0, row.indexOf("bold")).match(/(?:\x1b\[[0-9;]*m)+$/)?.[0] ?? "";
      const startAsk = async (
        gateway: ReturnType<typeof startFakeGateway>,
        label: string,
      ) => {
        const stderrPath = join(root.root, `${label}-stderr.log`);
        writeFileSync(stderrPath, "");
        const session = await TmuxSession.create({
          isolated: true,
          cmd: terminalCommand(["ask", "--auto", "--no-save", prompt]),
          cwd: root.workspace,
          env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
          width: 120,
          height: 40,
          remainOnExit: true,
          stderrPath,
        });
        sessions.push(session);
        return { session, stderrPath };
      };

      const held = heldFakeGatewayFinalText();
      const heldGateway = startFakeGateway([() => held.response]);
      gateways.push(heldGateway);
      const { session, stderrPath } = await startAsk(heldGateway, "streamed");
      held.send(calibration);
      await session.waitForText("Calibration bold line.", TIMEOUT);
      held.send(streamedLine);
      await session.waitForText("Streaming bold", 5_000);

      const escapedMid = await session.captureFullScrollbackEscapes();
      const plainMid = await session.captureFullScrollback();
      expect(plainMid).not.toContain("**");
      const calibrationRow =
        escapedMid.split("\n").find((row) => row.includes("Calibration")) ?? "";
      const streamedRow =
        escapedMid.split("\n").find((row) => row.includes("Streaming")) ?? "";
      expect(sgrBeforeBold(calibrationRow)).toMatch(boldSgr);
      expect(sgrBeforeBold(streamedRow)).toBe(sgrBeforeBold(calibrationRow));

      held.send(streamedRest);
      await session.waitForText("words", TIMEOUT);
      await session.waitForText("code", TIMEOUT);
      const plainPartial = await session.captureFullScrollback();
      expect(plainPartial).not.toContain("**");
      expect(plainPartial).not.toContain("`");
      expect(
        plainPartial.split("\n").some((row) => row.trimStart().startsWith("| a")),
      ).toBe(false);

      held.send(ending);
      held.release("");
      await waitForExit(session);
      const streamed = await session.captureFullScrollback();
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const onePieceGateway = startFakeGateway([fakeGatewayFinalText(fullReply)]);
      gateways.push(onePieceGateway);
      const onePiece = await startAsk(onePieceGateway, "one-piece");
      await waitForExit(onePiece.session);
      expect(rowsOf(streamed)).toEqual(
        rowsOf(await onePiece.session.captureFullScrollback()),
      );
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
    "a shell snapshot fallback in terminal mode is a notice on its own row",
    async () => {
      const root = createRoot();
      // A 9 MB alias exceeds the 8 MiB capture limit, so the snapshot falls back once.
      writeStartupFiles(
        root.home,
        "alias fxbig=\"$(head -c 9000000 /dev/zero | tr '\\0' x)\"\n" +
          "alias fxsmall='printf FX_FULL_STARTUP_ALIAS'\n",
      );
      const gateway = startFakeGateway([
        userShellRun("first", "fxsmall"),
        fakeGatewayFinalText("Fallback checked.\n"),
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--yolo", "--no-save", "Check the fallback."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      const notice = "shell snapshot unavailable (the captured state exceeded 8 MiB)";
      expect(occurrences(scrollback, notice)).toBe(1);
      expect(scrollback).toMatch(/^! startup: shell snapshot unavailable /m);
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
    "a gateway error in terminal mode prints on its own row",
    async () => {
      const root = createRoot();
      const message = "The gateway refused this request for a test reason.";
      const gateway = startFakeGateway([
        () => Response.json({ error: { message, type: "invalid_request_error" } }, { status: 400 }),
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--yolo", "--no-save", "Trigger the gateway error."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForPane((pane) => /__FX_EXIT_\d+__/.test(pane), TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(occurrences(scrollback, message)).toBe(1);
      expect(scrollback).toMatch(
        /^fx ask: API request failed · HTTP 400 · invalid_request_error: The gateway refused this request for a test reason\.\s*$/m,
      );
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

  // `fx ask` shows no question, so the prose before one ends its line as it
  // does before any other tool.
  const ASK_QUESTION = { questions: [{ question: "Choose next step?", options: [{ label: "Run tests" }, { label: "Stop" }] }] };
  for (const [placement, settings, call] of [
    ["direct", {}, { name: "ask_user_question", input: ASK_QUESTION }],
    ["toolbox", { tool_placement: { ask_user_question: "toolbox" } }, { name: "toolbox", input: { run: "ask_user_question", arguments: ASK_QUESTION } }],
  ] as const) {
    test.skipIf(!tmuxAvailable())(
      `ask in a terminal ends the prose line before a ${placement} question`,
      async () => {
        const root = createShortRoot();
        mkdirSync(join(root.home, ".fx"), { recursive: true });
        writeFileSync(join(root.home, ".fx", "settings.json"), JSON.stringify(settings));
        const gateway = startFakeGateway([
          fakeGatewaySse([
            { type: "text-delta", id: "prose_1", delta: "One question first." },
            { type: "tool-call", toolCallId: "ask_1", toolName: call.name, input: call.input },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
          ]),
          fakeGatewayFinalText("Done after the question."),
        ]);
        gateways.push(gateway);

        const session = await TmuxSession.create({
          isolated: true,
          cmd: terminalCommand(["ask", "--no-save", "Ask me, then finish."]),
          cwd: root.workspace,
          env: { ...gatewayEnv(root.home, gateway), NO_COLOR: "1" },
          width: 100,
          height: 30,
          remainOnExit: true,
        });
        sessions.push(session);

        await session.waitForText("__FX_EXIT_0__", TIMEOUT);
        const rows = (await session.captureFullScrollback()).split("\n").map((row) => row.trimEnd());
        const prose = rows.indexOf("  One question first.");
        expect(prose, rows.join("\n")).toBeGreaterThan(0);
        expect(rows[prose + 1]).toBe("  Done after the question.");
      },
      TIMEOUT,
    );
  }

  test.skipIf(!tmuxAvailable())(
    "a titled MCP choice lists each option with one number and reviews its title",
    async () => {
      const root = createRoot();
      writeMcpFormProfile(root, {
        type: "string",
        title: "Team",
        oneOf: [
          { const: "design", title: "Design" },
          { const: "documentation", title: "Documentation" },
          { const: "operations", title: "Operations" },
          { const: "acme-playground", title: "Acme Playground" },
        ],
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayFinalText("Team saved.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Choose the team."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), FX_MODEL: MCP_MODEL, NO_COLOR: undefined },
        width: 100,
        height: 40,
        minimumHistoryLines: 200,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Choose a number or enter a value:", 60_000);
      const menu = await session.captureFullScrollback();
      expect(menu).toMatch(/^ {2}1\. Design$/m);
      expect(menu).toMatch(/^ {2}4\. Acme Playground$/m);
      expect(menu).not.toContain("[4]");

      await session.sendText("4");
      await session.waitForText("Current values:", TIMEOUT);
      const review = await session.captureFullScrollback();
      expect(review).toMatch(/^- Team: Acme Playground$/m);
      expect(review).not.toContain("acme-playground");

      await session.sendText("1");
      await session.waitForText("Team saved.", TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      expect(readFileSync(join(root.root, "mcp-wire.jsonl"), "utf8")).toContain(
        '"answer":"acme-playground"',
      );
    },
    90_000,
  );

  test.skipIf(!tmuxAvailable())(
    "a typed label that matches two titled choices asks again, and a number names its choice",
    async () => {
      const root = createRoot();
      writeMcpFormProfile(root, {
        type: "string",
        title: "Team",
        oneOf: [
          { const: "a", title: "Decline" },
          { const: "c", title: "Decline" },
          { const: "d", title: "Decline (c)" },
        ],
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayFinalText("Team saved.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);
      const tracePath = join(root.root, "fx-trace.log");

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Choose the team."]),
        cwd: root.workspace,
        env: {
          ...gatewayEnv(root.home, gateway),
          FX_MODEL: MCP_MODEL,
          NO_COLOR: undefined,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "mcp",
        },
        width: 100,
        height: 40,
        minimumHistoryLines: 200,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Choose a number or enter a value:", 60_000);
      await session.sendText("Decline (c)");
      await session.waitForText("That matches more than one choice. Type its number.", 15_000);
      await session.sendText("3");
      await session.waitForText("Current values:", TIMEOUT);
      const review = await session.captureFullScrollback();
      expect(review).toMatch(/^- Team: Decline \(c\)$/m);

      await session.sendText("1");
      await session.waitForText("Team saved.", TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      expect(readFileSync(join(root.root, "mcp-wire.jsonl"), "utf8")).toContain('"answer":"d"');
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("dropped an ambiguous typed choice answer");
      expect(trace).not.toContain("Decline (c)");
    },
    90_000,
  );

  test.skipIf(!tmuxAvailable())(
    "a typed title shaped like an option index names its own choice",
    async () => {
      const root = createRoot();
      writeMcpFormProfile(root, {
        type: "string",
        title: "Team",
        oneOf: [
          { const: "a", title: '{"option":1}' },
          { const: "b", title: "Beta" },
        ],
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayFinalText("Team saved.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Choose the team."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), FX_MODEL: MCP_MODEL, NO_COLOR: undefined },
        width: 100,
        height: 40,
        minimumHistoryLines: 200,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Choose a number or enter a value:", 60_000);
      await session.sendText('{"option":1}');
      await session.waitForText("Current values:", TIMEOUT);
      const review = await session.captureFullScrollback();
      expect(review).toContain('- Team: {"option":1}');
      expect(review).not.toContain("- Team: Beta");

      await session.sendText("1");
      await session.waitForText("Team saved.", TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      expect(readFileSync(join(root.root, "mcp-wire.jsonl"), "utf8")).toContain('"answer":"a"');
    },
    90_000,
  );

  test.skipIf(!tmuxAvailable())(
    "fx ask in a terminal answers ask_user_question as unavailable and opens no choice prompt",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([
        fakeGatewayToolCall("question", "ask_user_question", {
          questions: [{
            question: "Pick one",
            options: [{ label: "Alpha", description: "First" }, { label: "Beta", description: "Second" }],
          }],
        }),
        fakeGatewayFinalText("Question unavailable handled.\n"),
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Ask me a question."]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 100,
        height: 40,
        minimumHistoryLines: 200,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Question unavailable handled.", TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const screen = await session.captureFullScrollback();
      expect(screen).not.toContain("Choose a number or enter a value:");
      expect(screen).not.toContain("Pick one");
      expect(gateway.requests[1]?.body).toContain("only available in the interactive shell");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "an MCP form answered mid-turn keeps its lines, and the next tool and the final reply stay visible",
    async () => {
      const root = createMcpFormRoot({ type: "string", title: "Release note" });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayToolCall("after_form", "shell", {
          request: { action: "run", profile: "clean", yield_time_ms: 30_000, command: "printf after-form-output" },
        }),
        fakeGatewayFinalText("Form and shell complete.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Fill the form, then run a command."]),
        cwd: root.workspace,
        env: mcpFormEnv(root.home, gateway),
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Enter a value:", MCP_TIMEOUT);
      await session.sendText("local-value");
      await session.waitForText("Current values:", MCP_TIMEOUT);
      await session.sendText("1");
      await session.waitForText("Form and shell complete.", MCP_TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", MCP_TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("Enter a value: local-value");
      expect(scrollback).toContain("Running printf after-form-output");
      expect(scrollback).toContain("Form and shell complete.");
    },
    MCP_TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "a long MCP form prompt line keeps its full text at 120 columns",
    async () => {
      const question =
        "Describe the release note for the ask presentation fix, keeping every word of this long prompt line " +
        "visible across the wrapped rows until the tail LONG_PROMPT_TAIL is printed.";
      const root = createMcpFormRoot({ type: "string", title: question });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayFinalText("Long prompt answered.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--auto", "--no-save", "Answer the long prompt."]),
        cwd: root.workspace,
        env: mcpFormEnv(root.home, gateway),
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Enter a value:", MCP_TIMEOUT);
      await session.sendText("local-value");
      await session.waitForText("Current values:", MCP_TIMEOUT);
      await session.sendText("1");
      await session.waitForText("Long prompt answered.", MCP_TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", MCP_TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(withoutWhitespace(scrollback)).toContain(withoutWhitespace(question));
    },
    MCP_TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "an approval prompt in terminal mode keeps its lines, and the next tool and the final reply stay visible",
    async () => {
      const root = createAskPermissionRoot();
      writeFileSync(join(root.workspace, "approval-fixture.txt"), "approval fixture contents\n");
      const marker = join(root.workspace, "approved-marker.txt");
      const gateway = startFakeGateway([
        fakeShellRun("approve_shell", `touch ${JSON.stringify(marker)}`, { timeout_ms: 600_000 }),
        fakeGatewayToolCall("after_approval", "read_file", { path: "approval-fixture.txt" }),
        fakeGatewayFinalText("Approval flow complete.\n"),
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--no-save", "Touch the marker, then read the fixture."]),
        cwd: root.workspace,
        env: permissionAskEnv(root.home, gateway),
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Approve? [y/N]", MCP_TIMEOUT);
      await session.sendText("y");
      await session.waitForText("Approval flow complete.", MCP_TIMEOUT);
      await session.waitForText("__FX_EXIT_0__", MCP_TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toMatch(/^fx wants to run:\s*$/m);
      expect(scrollback).toContain("Approve? [y/N] y");
      expect(scrollback).toContain("Reading approval-fixture.txt");
      expect(scrollback).toContain("Approval flow complete.");
      expect(existsSync(marker)).toBe(true);
    },
    MCP_TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "a blocked tool in terminal mode shows its guidance on its own line",
    async () => {
      const root = createAskPermissionRoot();
      const gateway = startFakeGateway([
        fakeGatewayToolCall("blocked_install", "install_skill", { source: "owner/repo@blocked-skill" }),
        fakeGatewayFinalText("Blocked action handled.\n"),
      ]);
      gateways.push(gateway);

      // With stdin from /dev/null the approval prompt is unavailable, so the call is refused with guidance.
      const session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--no-save", "Install the blocked skill."], "/dev/null"),
        cwd: root.workspace,
        env: permissionAskEnv(root.home, gateway),
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      // A refused call ends the run with status 1, so no later reply prints.
      await session.waitForText("__FX_EXIT_1__", MCP_TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toMatch(
        /^! permission: fx ask: permission required for tool execution in noninteractive mode\s*$/m,
      );
      expect(scrollback).toContain("fx ask: rerun with --auto to review this exact action automatically");
    },
    MCP_TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "Ctrl-C while an MCP form is open ends fx and turns autowrap back on",
    async () => {
      const root = createMcpFormRoot({ type: "string", title: "Release note" });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "toolbox", { open: MCP_TOOL }),
        fakeGatewayToolCall("call_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
        fakeGatewayFinalText("Form was not answered.\n"),
      ], { models: [{ id: MCP_MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      // fx is the pane's own process, so the Ctrl-C reaches fx and no wrapper shell.
      const session = await TmuxSession.create({
        isolated: true,
        cmd: directCommand(["ask", "--auto", "--no-save", "Fill the form, then cancel it."]),
        cwd: root.workspace,
        env: mcpFormEnv(root.home, gateway),
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);
      const outputPath = join(root.root, "pane-output.bin");
      session.startPaneOutputCapture(outputPath);

      await session.waitForText("Enter a value:", MCP_TIMEOUT);
      await session.sendKeys("C-c");
      await session.waitForText("Pane is dead", MCP_TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toMatch(/^MCP server fixture requests Release note \(required\)\s*$/m);
      expect(scrollback).toMatch(/^Reason: Choose the next step\s*$/m);
      expect(scrollback).toMatch(/^Enter a value: \^C\s*$/m);
      // fx ends by re-raising SIGINT, which a shell reports as exit 130. tmux 3.6 names the
      // signal "2" in its dead-pane line and tmux 3.6a names it "int".
      expect(session.paneStatus()).toEqual({ dead: true, status: null });
      expect(scrollback).toMatch(/Pane is dead \(signal (2|int),/);

      // The restore sequence comes after the last autowrap change, and it turns autowrap on.
      const output = await readOutputUntil(outputPath, "\x1b[?25h\x1b[?7h");
      const lastAutowrapOff = output.lastIndexOf("\x1b[?7l");
      expect(output.lastIndexOf("\x1b[?7h")).toBeGreaterThan(lastAutowrapOff);
      expect(output.slice(lastAutowrapOff)).toContain("\x1b[?25h\x1b[?7h");
    },
    MCP_TIMEOUT,
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
        await session.waitForPane((pane) => pane.includes("SECRET_CHECK_DONE") && turnSettled(pane), TIMEOUT);
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
