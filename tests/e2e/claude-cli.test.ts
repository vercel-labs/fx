import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN, runFx } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

// A stand-in for the `claude` command. It answers `auth status`, records every
// invocation, and replays a canned stream-json turn, so fx's Claude provider can
// be checked without a Claude account or the network.
const FAKE_CLAUDE = `#!/bin/sh
dir="$FAKE_CLAUDE_DIR"
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  # Like the real CLI, an API key in the environment hides the subscription login.
  if [ -n "$ANTHROPIC_API_KEY" ]; then echo '{"loggedIn":true,"authMethod":"api_key"}'; exit 0; fi
  cat "$dir/status.json"; exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  echo login >> "$dir/calls.log"
  cp "$dir/status-after-login.json" "$dir/status.json"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then echo logout >> "$dir/calls.log"; exit 0; fi
n=$(cat "$dir/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$dir/count"
printf '%s\\n' "$@" > "$dir/argv.$n"
cat > "$dir/stdin.$n"
if [ -n "$ANTHROPIC_API_KEY" ]; then echo present > "$dir/apikey.$n"; else echo absent > "$dir/apikey.$n"; fi
echo "$$" > "$dir/pid.$n"
pwd -P > "$dir/cwd.$n"
if [ -f "$dir/bgerr" ]; then (sleep 8 >/dev/null &); fi
if [ -f "$dir/exit-early" ]; then cat "$dir/stream.default"; exit 0; fi
if [ -f "$dir/stderr" ]; then cat "$dir/stderr" >&2; exit 3; fi
if [ -f "$dir/stream.$n" ]; then cat "$dir/stream.$n"; else cat "$dir/stream.default"; fi
if [ -f "$dir/hold" ]; then
  # Like Claude Code, exit cleanly when asked to, so its own commands can stop.
  trap 'echo term > "$dir/term"; exit 0' TERM
  sleep 30 &
  wait
fi
`;

const SIGNED_IN = JSON.stringify({ loggedIn: true, authMethod: "claude.ai", email: "person@example.com", orgId: "org-test-1", subscriptionType: "max" });
const SIGNED_OUT = JSON.stringify({ loggedIn: false });

const line = (value: unknown) => JSON.stringify(value) + "\n";
const textDelta = (text: string, index = 0) => line({ type: "stream_event", event: { type: "content_block_delta", index, delta: { type: "text_delta", text } } });
const textStart = (index = 0) => line({ type: "stream_event", event: { type: "content_block_start", index, content_block: { type: "text", text: "" } } });
const blockStop = (index = 0) => line({ type: "stream_event", event: { type: "content_block_stop", index } });
const init = (sessionId: string) => line({ type: "system", subtype: "init", session_id: sessionId });
const result = (sessionId: string, text: string, extra: Record<string, unknown> = {}) =>
  line({ type: "result", subtype: "success", is_error: false, result: text, stop_reason: "end_turn", session_id: sessionId, usage: { input_tokens: 3, output_tokens: 5 }, ...extra });

function textTurn(sessionId: string, text: string) {
  return init(sessionId) + textStart() + textDelta(text) + blockStop() + result(sessionId, text);
}

function toolTurn(sessionId: string) {
  return init(sessionId)
    + textStart(0) + textDelta("Reading.", 0) + blockStop(0)
    + line({ type: "stream_event", event: { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "toolu_e2e_1", name: "Read", input: {} } } })
    + line({ type: "stream_event", event: { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: JSON.stringify({ file_path: "note.txt" }) } } })
    + blockStop(1)
    + line({ type: "user", message: { role: "user", content: [{ tool_use_id: "toolu_e2e_1", type: "tool_result", content: "fixture contents", is_error: false }] } })
    + textStart(0) + textDelta("The note says fixture contents.", 0) + blockStop(0)
    + result(sessionId, "The note says fixture contents.");
}

type Fixture = {
  home: string;
  dir: string;
  workspace: string;
  env: Record<string, string>;
  calls: () => string[];
  argv: (n: number) => string[];
  rawArgv: (n: number) => string[];
  stdin: (n: number) => string;
  runs: () => number;
  cleanup: () => void;
};

function createFixture(opts: { status?: string; statusAfterLogin?: string; stream?: string } = {}): Fixture {
  const home = createIsolatedTestHome();
  const dir = mkdtempSync(join(tmpdir(), "fx-fake-claude-"));
  const workspace = join(dir, "workspace");
  mkdirSync(workspace);
  const bin = join(dir, "claude");
  writeFileSync(bin, FAKE_CLAUDE);
  chmodSync(bin, 0o755);
  writeFileSync(join(dir, "status.json"), opts.status ?? SIGNED_IN);
  writeFileSync(join(dir, "status-after-login.json"), opts.statusAfterLogin ?? SIGNED_IN);
  writeFileSync(join(dir, "stream.default"), opts.stream ?? textTurn("sess-default-1", "pong"));
  const read = (name: string) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "");
  return {
    home,
    dir,
    workspace,
    env: {
      HOME: home,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_CLAUDE_BIN: bin,
      FAKE_CLAUDE_DIR: dir,
      FX_PROVIDER: "claude",
    },
    calls: () => read("calls.log").split("\n").filter(Boolean),
    argv: n => read(`argv.${n}`).split("\n").filter(Boolean),
    rawArgv: n => read(`argv.${n}`).split("\n").slice(0, -1),
    stdin: n => read(`stdin.${n}`),
    runs: () => Number(read("count") || "0"),
    cleanup: () => {
      cleanupIsolatedTestHome(home);
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

function flagValue(argv: string[], flag: string): string | undefined {
  const at = argv.indexOf(flag);
  return at >= 0 ? argv[at + 1] : undefined;
}

describe("claude provider (delegated Claude Code)", () => {
  test("a turn runs claude -p with the prompt on stdin, denied prompts, and no API key", async () => {
    const f = createFixture();
    try {
      const run = await runFx(["ask", "--json", "--no-save", "Reply with pong"], {
        cwd: f.workspace,
        env: { ...f.env, ANTHROPIC_API_KEY: "sk-ant-test-must-not-reach-claude" },
        timeoutMs: 20000,
      });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(JSON.parse(run.stdout).output).toBe("pong");
      expect(f.runs()).toBe(1);

      const argv = f.argv(1);
      expect(argv).toContain("-p");
      expect(flagValue(argv, "--output-format")).toBe("stream-json");
      expect(argv).toContain("--include-partial-messages");
      expect(flagValue(argv, "--permission-prompts")).toBe("none");
      expect(argv).not.toContain("--model");
      expect(argv).not.toContain("--resume");
      // No settings files load, so a repository's own settings cannot run hooks.
      const raw = f.rawArgv(1);
      expect(raw[raw.indexOf("--setting-sources") + 1]).toBe("");
      expect(argv).toContain("--strict-mcp-config");
      // The prompt travels on stdin, never in argv.
      expect(argv.join(" ")).not.toContain("Reply with pong");
      expect(f.stdin(1)).toContain("Reply with pong");
      // Claude Code works in the session's workspace.
      expect(readFileSync(join(f.dir, "cwd.1"), "utf8").trim()).toBe(realpathSync(f.workspace));
      // A subscription turn must not be billed to an API key from the environment.
      expect(readFileSync(join(f.dir, "apikey.1"), "utf8").trim()).toBe("absent");
    } finally {
      f.cleanup();
    }
  }, 30000);

  test.each([
    ["ask", "manual"],
    ["auto", "auto"],
    ["full-access", "bypassPermissions"],
  ])("fx permission mode %s runs Claude Code in %s mode with prompts denied", async (fxMode, claudeMode) => {
    const f = createFixture();
    try {
      const run = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PERMISSION_MODE: fxMode }, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      const argv = f.argv(1);
      expect(flagValue(argv, "--permission-mode")).toBe(claudeMode);
      expect(flagValue(argv, "--permission-prompts")).toBe("none");
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("tools Claude ran are recorded and the turn ends without another model call", async () => {
    const f = createFixture({ stream: toolTurn("sess-tool-1") });
    try {
      const run = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(JSON.parse(run.stdout).output).toBe("Reading.\n\nThe note says fixture contents.");
      expect(f.runs()).toBe(1);
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("a resumed fx session continues the same Claude session and sends only the new prompt", async () => {
    const f = createFixture();
    try {
      writeFileSync(join(f.dir, "stream.1"), textTurn("sess-resume-1", "first answer"));
      writeFileSync(join(f.dir, "stream.2"), textTurn("sess-resume-1", "second answer"));
      const first = await runFx(["ask", "--json", "First question"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);
      expect(saved.output).toBe("first answer");

      const second = await runFx(["ask", "--json", "--resume", saved.session_id, "Second question"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (second.code !== 0) throw new Error(second.stdout + second.stderr);
      expect(JSON.parse(second.stdout).output).toBe("second answer");

      expect(f.runs()).toBe(2);
      expect(flagValue(f.argv(2), "--resume")).toBe("sess-resume-1");
      expect(f.stdin(2).trim()).toBe("Second question");
    } finally {
      f.cleanup();
    }
  }, 45000);

  test("a missing Claude session is replayed as text instead of failing the turn", async () => {
    const f = createFixture();
    try {
      writeFileSync(join(f.dir, "stream.1"), textTurn("sess-gone-1", "first answer"));
      writeFileSync(join(f.dir, "stream.2"), line({ type: "result", subtype: "error_during_execution", is_error: true, result: "No conversation found with session ID: sess-gone-1" }));
      writeFileSync(join(f.dir, "stream.3"), textTurn("sess-new-1", "recovered answer"));
      const first = await runFx(["ask", "--json", "First question"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);

      const second = await runFx(["ask", "--json", "--resume", saved.session_id, "Second question"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (second.code !== 0) throw new Error(second.stdout + second.stderr);
      expect(JSON.parse(second.stdout).output).toBe("recovered answer");
      expect(f.runs()).toBe(3);
      expect(f.argv(3)).not.toContain("--resume");
      expect(f.stdin(3)).toContain("First question");
      expect(f.stdin(3)).toContain("Second question");
    } finally {
      f.cleanup();
    }
  }, 45000);

  test("an API key in the environment does not hide the subscription sign-in", async () => {
    const f = createFixture();
    try {
      const run = await runFx(["ask", "--json", "--no-save", "hello"], {
        cwd: f.workspace,
        env: { ...f.env, ANTHROPIC_API_KEY: "sk-ant-test-env-key", ANTHROPIC_BASE_URL: "https://proxy.example.com" },
        timeoutMs: 20000,
      });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(JSON.parse(run.stdout).output).toBe("pong");
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("a clean exit with no result is a failure, not an empty answer", async () => {
    const f = createFixture({ stream: init("sess-trunc-1") + textStart() + textDelta("half an ans") });
    try {
      const run = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(run.code).not.toBe(0);
      expect(run.stdout + run.stderr).toContain("ended without a result");
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("a command that exits before reading the prompt still reports its own error", async () => {
    const f = createFixture({ stream: line({ type: "result", subtype: "error_during_execution", is_error: true, result: "Not logged in. Please run /login" }) });
    try {
      writeFileSync(join(f.dir, "exit-early"), "");
      const run = await runFx(["ask", "--no-save"], { cwd: f.workspace, env: f.env, stdin: "y".repeat(2_000_000), timeoutMs: 30000 });
      expect(run.code).not.toBe(0);
      // The CLI's own sign-in error, not a bare launch failure.
      expect(run.stdout + run.stderr).toContain("authentication failed");
    } finally {
      f.cleanup();
    }
  }, 45000);

  test("a signed-out Claude Code stops the turn with sign-in guidance", async () => {
    const f = createFixture({ status: SIGNED_OUT });
    try {
      const run = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(run.code).not.toBe(0);
      expect(run.stdout + run.stderr).toContain("fx login claude");
      expect(f.runs()).toBe(0);
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("a usage-limit error from Claude Code is shown once with its reset time and is not retried", async () => {
    const f = createFixture({ stream: line({ type: "result", subtype: "error_during_execution", is_error: true, result: "Claude usage limit reached. Resets at 5pm." }) });
    try {
      const run = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      expect(run.code).not.toBe(0);
      expect(run.stdout + run.stderr).toContain("Claude usage limit reached. Resets at 5pm.");
      // fx retries rate limits patiently, but a usage limit cannot clear on retry.
      expect(f.runs()).toBe(1);
    } finally {
      f.cleanup();
    }
  }, 45000);

  test("a Claude Code crash without a result shows what it wrote to stderr", async () => {
    const f = createFixture();
    try {
      writeFileSync(join(f.dir, "stderr"), "claude: unexpected failure code E_TEST_CRASH\u0007\n");
      const run = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      expect(run.code).not.toBe(0);
      const output = run.stdout + run.stderr;
      expect(output).toContain("E_TEST_CRASH");
      expect(output).not.toContain("\u0007");
      expect(f.runs()).toBe(1);
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("a background process holding stderr open does not delay or hang the turn", async () => {
    const f = createFixture();
    try {
      writeFileSync(join(f.dir, "bgerr"), "");
      const run = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(JSON.parse(run.stdout).output).toBe("pong");
      expect(run.elapsedMs).toBeLessThan(6000);

      writeFileSync(join(f.dir, "stderr"), "claude: failed while a helper held stderr\n");
      const failed = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(failed.code).not.toBe(0);
      expect(failed.stdout + failed.stderr).toContain("failed while a helper held stderr");
      expect(failed.elapsedMs).toBeLessThan(6000);
    } finally {
      f.cleanup();
    }
  }, 40000);

  test("fx provider claude selects it and fx models lists the aliases", async () => {
    const f = createFixture();
    try {
      const select = await runFx(["provider", "claude"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      if (select.code !== 0) throw new Error(select.stdout + select.stderr);
      expect(select.stdout).toContain("Provider set to Claude.");
      const models = await runFx(["models"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      if (models.code !== 0) throw new Error(models.stdout + models.stderr);
      for (const alias of ["default", "opus", "sonnet", "haiku"]) expect(models.stdout).toContain(alias);
      // Selecting a provider never starts a model turn.
      expect(f.runs()).toBe(0);
    } finally {
      f.cleanup();
    }
  }, 45000);

  test("a chosen model alias reaches claude as --model", async () => {
    const f = createFixture();
    try {
      const run = await runFx(["ask", "--no-save", "--model", "opus", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(flagValue(f.argv(1), "--model")).toBe("opus");
    } finally {
      f.cleanup();
    }
  }, 30000);

  test("fx login claude leaves a signed-in CLI alone and runs claude auth login when signed out", async () => {
    const signedIn = createFixture();
    try {
      const run = await runFx(["login", "claude"], { cwd: signedIn.workspace, env: { ...signedIn.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(run.stdout).toContain("Signed in with Claude.");
      expect(signedIn.calls()).toEqual([]);
    } finally {
      signedIn.cleanup();
    }

    const signedOut = createFixture({ status: SIGNED_OUT, statusAfterLogin: SIGNED_IN });
    try {
      const run = await runFx(["login", "claude"], { cwd: signedOut.workspace, env: { ...signedOut.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(run.stdout).toContain("Signed in with Claude.");
      expect(signedOut.calls()).toEqual(["login"]);
    } finally {
      signedOut.cleanup();
    }
  }, 45000);

  test("fx login claude fails clearly when the CLI never signs in or is missing", async () => {
    const stuck = createFixture({ status: SIGNED_OUT, statusAfterLogin: SIGNED_OUT });
    try {
      const run = await runFx(["login", "claude"], { cwd: stuck.workspace, env: { ...stuck.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      expect(run.code).not.toBe(0);
      expect(run.stdout + run.stderr).toContain("claude auth login did not complete");
    } finally {
      stuck.cleanup();
    }

    const missing = createFixture();
    try {
      const run = await runFx(["login", "claude"], { cwd: missing.workspace, env: { ...missing.env, FX_PROVIDER: undefined, FX_CLAUDE_BIN: join(missing.dir, "no-such-claude") }, timeoutMs: 20000 });
      expect(run.code).not.toBe(0);
      expect(run.stdout + run.stderr).toContain("could not find the claude command");
    } finally {
      missing.cleanup();
    }
  }, 45000);

  test("fx logout claude never signs the user out of Claude Code", async () => {
    const f = createFixture();
    try {
      const run = await runFx(["logout", "claude"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: undefined }, timeoutMs: 20000 });
      if (run.code !== 0) throw new Error(run.stdout + run.stderr);
      expect(run.stdout).toContain("claude auth logout");
      expect(f.calls()).toEqual([]);
    } finally {
      f.cleanup();
    }
  }, 30000);
});

describe.skipIf(!tmuxAvailable())("claude provider in the terminal UI", () => {
  let session: TmuxSession | null = null;
  let fixture: Fixture | null = null;

  afterEach(async () => {
    if (session) await session.kill();
    session = null;
    fixture?.cleanup();
    fixture = null;
  });

  test("/login claude hands the terminal to claude auth login and then selects Claude", async () => {
    const f = createFixture({ status: SIGNED_OUT, statusAfterLogin: SIGNED_IN });
    fixture = f;
    session = await TmuxSession.create({ cmd: FX_BIN, cwd: f.workspace, env: { ...f.env, FX_PROVIDER: undefined } });
    await session.waitForComposer(15_000);
    await session.sendText("/login claude");
    await session.waitForText("Switched to Claude subscription", 30_000);
    expect(f.calls()).toEqual(["login"]);
    await session.waitForComposer(15_000);
  }, 60000);

  test("tools Claude ran appear as transcript rows with their main argument", async () => {
    const f = createFixture({ stream: toolTurn("sess-rows-1") });
    fixture = f;
    session = await TmuxSession.create({ cmd: FX_BIN, cwd: f.workspace, env: f.env });
    await session.waitForComposer(15_000);
    await session.sendText("Read note.txt");
    const pane = await session.waitForText("The note says fixture contents.", 30_000);
    expect(pane).toContain("1 tool call");
    expect(pane).toContain("Read note.txt");
  }, 60000);

  test("interrupting a turn stops the Claude Code process", async () => {
    // The terminal holds back the trailing block of a stream, so send several
    // paragraphs and wait for an earlier one.
    const f = createFixture({
      stream: init("sess-hold-1") + textStart() + textDelta("CLAUDE_PARTIAL_ONE\n\n") + textDelta("CLAUDE_PARTIAL_TWO\n\n") + textDelta("CLAUDE_PARTIAL_THREE\n"),
    });
    fixture = f;
    writeFileSync(join(f.dir, "hold"), "");
    session = await TmuxSession.create({ cmd: FX_BIN, cwd: f.workspace, env: f.env });
    await session.waitForComposer(15_000);
    await session.sendText("Do the long task");
    await session.waitForText("CLAUDE_PARTIAL_ONE", 20_000);

    const pid = Number(readFileSync(join(f.dir, "pid.1"), "utf8").trim());
    expect(Number.isInteger(pid) && pid > 0).toBe(true);
    const alive = () => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    expect(alive()).toBe(true);

    await session.sendInterruptEscapePair();
    const deadline = Date.now() + 15_000;
    while (alive() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 100));
    expect(alive()).toBe(false);
    // fx asks Claude Code to exit first so it can stop the commands it started.
    expect(existsSync(join(f.dir, "term"))).toBe(true);
    await session.waitForComposer(15_000);
  }, 90000);
});
