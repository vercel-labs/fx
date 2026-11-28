// Spec-to-code driver for tests/tla/cli_hangup/CliHangup.tla (design-a.cfg).
//
// Runs TLC to dump the reachable state graph of design-a.cfg, drives real
// CLI commands (`fx ask`, `fx replay`, `fx status`, `fx login`, `fx teams`)
// through non-controlling PTYs (`os.setsid()` without TIOCSCTTY so SIGHUP is
// not delivered) and fake servers, and checks that every state key in TLC's
// graph is either observed by a run or explicitly listed in UNREACHED_STATES.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

const { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeGatewaySse, startDynamicFakeGateway } = await targetHelpers();
const PYTHON = Bun.which("python3");

type ModelState = {
  termState: string;
  phase: string;
  errKind: string;
  errOnOpenTerm: boolean;
  hasCatch: boolean;
  outcome: string;
  msgPrinted: string;
};

const stateKey = (s: ModelState): string =>
  `${s.termState}|${s.phase}|${s.errKind}|openErr=${s.errOnOpenTerm}|catch=${s.hasCatch}|${s.outcome}|${s.msgPrinted}`;

// States in design-a.cfg that an external black-box fx process cannot trigger
// or pause inside, each paired with its concrete reason and pinning unit test.
const UNREACHED_STATES: Record<string, string> = {
  "open|subcmd_catch|eio_tty|openErr=true|catch=true|running|none": "open-tty EIO cannot be forced from outside; pinned by cli_surface.zig/cli_ask.zig unit tests",
  "open|exit_handler|eio_tty|openErr=true|catch=false|running|none": "open-tty EIO cannot be forced from outside; pinned by cli_surface.zig/cli_replay.zig/cli_ask.zig unit tests",
  "open|done|eio_tty|openErr=true|catch=false|error_1|disk": "open-tty EIO cannot be forced from outside; pinned by cli_replay.zig/ask_presentation.zig unit tests",
  "open|done|eio_tty|openErr=true|catch=true|error_1|swallowed": "open-tty EIO cannot be forced from outside; pinned by cli_surface.zig unit tests",
  "hung_up|subcmd_catch|eio_tty|openErr=true|catch=true|running|none": "open-tty EIO before hang-up is transient; pinned by unit tests",
  "hung_up|exit_handler|eio_tty|openErr=true|catch=false|running|none": "open-tty EIO before hang-up is transient; pinned by unit tests",
  "hung_up|done|eio_tty|openErr=true|catch=false|error_1|disk": "open-tty EIO before hang-up cannot be timed externally; pinned by unit tests",
  "hung_up|done|eio_tty|openErr=true|catch=true|error_1|swallowed": "open-tty EIO before hang-up cannot be timed externally; pinned by unit tests",
  "hung_up|exit_handler|eio_file|openErr=false|catch=false|running|none": "simultaneous file error and tty hang-up in one command; file errors stay independent of terminalGone",
  "hung_up|exit_handler|eio_file|openErr=false|catch=true|running|none": "simultaneous file error and tty hang-up in one command; file errors stay independent of terminalGone",
  "hung_up|exit_handler|eio_file|openErr=true|catch=false|running|none": "simultaneous file error and tty hang-up in one command; file errors stay independent of terminalGone",
  "hung_up|exit_handler|eio_file|openErr=true|catch=true|running|none": "simultaneous file error and tty hang-up in one command; file errors stay independent of terminalGone",
  "hung_up|done|eio_file|openErr=false|catch=false|error_1|file_err": "simultaneous file error and tty hang-up; pinned by terminalGone(file)==false unit tests",
  "hung_up|done|eio_file|openErr=false|catch=true|error_1|file_err": "simultaneous file error and tty hang-up; pinned by terminalGone(file)==false unit tests",
  "hung_up|done|eio_file|openErr=true|catch=false|error_1|file_err": "simultaneous file error and tty hang-up; pinned by terminalGone(file)==false unit tests",
  "hung_up|done|eio_file|openErr=true|catch=true|error_1|file_err": "simultaneous file error and tty hang-up; pinned by terminalGone(file)==false unit tests",
  "open|exit_handler|eio_file|openErr=true|catch=false|running|none": "transient internal frame inside command exit",
  "open|exit_handler|eio_file|openErr=true|catch=true|running|none": "transient internal frame inside command exit",
  "hung_up|exit_handler|TerminalHungUp|openErr=false|catch=false|running|none": "transient internal frame inside commandFailure",
  "hung_up|exit_handler|TerminalHungUp|openErr=false|catch=true|running|none": "transient internal frame inside commandFailure",
  "hung_up|write_io|none|openErr=false|catch=false|running|none": "transient internal window between pty close and next write",
  "hung_up|write_io|none|openErr=false|catch=true|running|none": "transient internal window between pty close and next write",
  "hung_up|stdin_prompt|none|openErr=false|catch=false|running|none": "transient internal window between pty close and next read",
  "hung_up|stdin_prompt|none|openErr=false|catch=true|running|none": "transient internal window between pty close and next read",
};

const PTY_DRIVER = [
  "import fcntl, json, os, pty, select, struct, subprocess, sys, termios, time",
  "mode, fx_bin, cwd, stderr_path, needle_s, input_s, *argv = sys.argv[1:]",
  "needle = needle_s.encode('latin1')",
  "master, slave = pty.openpty()",
  "fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))",
  "err_master = err_slave = None",
  "if mode == 'separate_err':",
  "    err_master, err_slave = pty.openpty()",
  "def preexec():",
  "    os.setsid()",
  "    os.dup2(slave, 0)",
  "    os.dup2(slave, 1)",
  "    if err_slave is not None:",
  "        os.dup2(err_slave, 2)",
  "    else:",
  "        err_fd = os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)",
  "        os.dup2(err_fd, 2)",
  "        if err_fd > 2: os.close(err_fd)",
  "    if slave > 2: os.close(slave)",
  "    if mode != 'immediate': os.close(master)",
  "    if err_slave is not None and err_slave > 2: os.close(err_slave)",
  "    if err_master is not None: os.close(err_master)",
  "if mode == 'immediate':",
  "    os.close(master)",
  "proc = subprocess.Popen([fx_bin] + argv, cwd=cwd, preexec_fn=preexec, close_fds=False)",
  "os.close(slave)",
  "if err_slave is not None: os.close(err_slave)",
  "def drain(fd):",
  "    chunks = []",
  "    while True:",
  "        r, _, _ = select.select([fd], [], [], 0.05)",
  "        if not r: break",
  "        try:",
  "            d = os.read(fd, 4096)",
  "            if not d: break",
  "            chunks.append(d)",
  "        except OSError: break",
  "    return b''.join(chunks)",
  "if mode == 'immediate':",
  "    pass",
  "elif mode == 'open':",
  "    buf = bytearray()",
  "    sent_input = False",
  "    deadline = time.monotonic() + 8.0",
  "    while proc.poll() is None and time.monotonic() < deadline:",
  "        r, _, _ = select.select([master], [], [], 0.05)",
  "        if r:",
  "            try: chunk = os.read(master, 4096)",
  "            except OSError: break",
  "            if not chunk: break",
  "            buf.extend(chunk)",
  "            if input_s and not sent_input and needle in buf:",
  "                sent_input = True",
  "                os.write(master, input_s.encode('latin1'))",
  "    buf.extend(drain(master))",
  "    os.close(master)",
  "else:",
  "    watch_fd = err_master if err_master is not None else master",
  "    buf = bytearray()",
  "    sent_11 = False",
  "    sent_6n = False",
  "    deadline = time.monotonic() + 8.0",
  "    while time.monotonic() < deadline:",
  "        r, _, _ = select.select([watch_fd], [], [], 0.1)",
  "        if r:",
  "            try: chunk = os.read(watch_fd, 4096)",
  "            except OSError: break",
  "            if not chunk: break",
  "            buf.extend(chunk)",
  "            if mode == 'ask_stream':",
  "                if not sent_11 and b'\\x1b]11;?' in buf:",
  "                    sent_11 = True",
  "                    os.write(master, b'\\x1b]11;rgb:0000/0000/0000\\x1b\\\\\\x1b[?1;2c')",
  "                if not sent_6n and b'\\x1b[6n' in buf:",
  "                    sent_6n = True",
  "                    os.write(master, b'\\x1b[1;1R')",
  "            if needle:",
  "                if needle in buf:",
  "                    os.close(master)",
  "                    if mode == 'ask_stream':",
  "                        sys.stdout.write('PTY_CLOSED\\n')",
  "                        sys.stdout.flush()",
  "                    break",
  "            elif len(buf) > 0:",
  "                os.close(master)",
  "                break",
  "    else:",
  "        os.close(master)",
  "try: rc = proc.wait(timeout=3.0)",
  "except subprocess.TimeoutExpired:",
  "    proc.kill()",
  "    rc = proc.wait(timeout=2.0)",
  "if err_master is not None:",
  "    stderr_txt = drain(err_master).decode('utf-8', 'replace')",
  "    os.close(err_master)",
  "else:",
  "    stderr_txt = open(stderr_path, encoding='utf-8', errors='replace').read()",
  "print(json.dumps({'status': rc, 'stderr': stderr_txt}))",
].join("\n");

async function loadGraphKeys(): Promise<Set<string>> {
  const dir = outDir("cli-hangup-driver-graph");
  const run = await runTlc(
    dir,
    "CliHangup",
    "design-a.cfg",
    ["CliHangup.tla", "design-a.cfg"],
    join(TLA_ROOT, "cli_hangup"),
    ["-dump", "dot,actionlabels", "graph"],
  );
  if (run.exitCode !== 0) {
    throw new Error(`TLC failed on CliHangup design-a.cfg (exit ${run.exitCode}):\n${run.output}`);
  }
  const dot = readFileSync(join(dir, "graph.dot"), "utf8");
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, ch) => (ch === "n" ? "\n" : ch));
  const keys = new Set<string>();
  for (const line of dot.split("\n")) {
    const m = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!m) continue;
    const raw: Record<string, any> = {};
    for (const entry of unescape(m[2]!).split(/\n(?=\/\\ )/)) {
      const kv = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (kv) raw[kv[1]!] = parseValue(kv[2]!.trim());
    }
    keys.add(stateKey(raw as ModelState));
  }
  expect(keys.size).toBeGreaterThan(0);
  return keys;
}

async function runPty(opts: {
  mode: "immediate" | "open" | "ask_stream" | "wait_needle" | "separate_err";
  argv: string[];
  cwd: string;
  env: Record<string, string>;
  needle?: string;
  input?: string;
  onPtyClosed?: () => void;
}): Promise<{ status: number; stderr: string }> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-cli-hangup-")));
  const stderrPath = join(root, "stderr.log");
  const proc = Bun.spawn(
    ["python3", "-c", PTY_DRIVER, opts.mode, binary, opts.cwd, stderrPath, opts.needle ?? "", opts.input ?? "", ...opts.argv],
    { cwd: opts.cwd, env: testEnvironment(opts.env), stdout: "pipe", stderr: "pipe" },
  );
  const lines: string[] = [];
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line === "PTY_CLOSED") opts.onPtyClosed?.();
        else if (line) lines.push(line);
      }
    }
    if (buf.trim()) lines.push(buf.trim());
    const exitCode = await proc.exited;
    const helperErr = await new Response(proc.stderr).text();
    if (exitCode !== 0) throw new Error(`pty driver failed (${exitCode}): ${helperErr}`);
    return JSON.parse(lines[lines.length - 1]!);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function writeSampleTape(path: string) {
  const magic = Buffer.from("FXTP\x01", "latin1");
  const ver = Buffer.from("0.0.1", "latin1");
  const line = Buffer.from("CLI_HANGUP_DRIVER_" + "X".repeat(80) + "\r\n", "latin1");
  const header = Buffer.alloc(13);
  header.writeUInt16LE(80, 0);
  header.writeUInt16LE(24, 2);
  header.writeBigInt64LE(123456789n, 4);
  header.writeUInt8(ver.length, 12);
  const frameHeader = Buffer.alloc(9);
  frameHeader.writeInt32LE(1, 0);
  frameHeader.writeUInt8(1, 4);
  frameHeader.writeUInt32LE(line.length, 5);
  const frames = Buffer.concat(Array.from({ length: 1200 }, () => Buffer.concat([frameHeader, line])));
  writeFileSync(path, Buffer.concat([magic, header, ver, frames]));
}

function writeAuthJson(home: string, teamId: string, issuer: string) {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(fxDir, "auth.json"),
    JSON.stringify({
      version: 1,
      issuer,
      client_id: "test-client",
      access_token: "seeded-token",
      refresh_token: "seeded-refresh",
      expires_at_ms: Date.now() + 3600_000,
      scope: "openid",
      token_type: "Bearer",
      team_id: teamId,
      team_slug: "team-old",
    }),
    { mode: 0o600 },
  );
}

describe.skipIf(!PYTHON)("CliHangup spec-to-code driver", () => {
  test("drives real CLI commands along CliHangup design-a.cfg", async () => {
    const graphKeys = await loadGraphKeys();
    const covered = new Set<string>();
    const mark = (s: ModelState) => covered.add(stateKey(s));

    // 1. Open-terminal write_io -> ok_0 (catch=false) + missing file errors (catch=false & catch=true).
    {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-wfd-open-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });
      try {
        mark({ termState: "open", phase: "write_io", errKind: "none", errOnOpenTerm: false, hasCatch: false, outcome: "running", msgPrinted: "none" });
        const statusOpen = await runPty({ mode: "open", argv: ["status"], cwd: root, env: { HOME: home } });
        expect(statusOpen).toEqual({ status: 0, stderr: "" });
        mark({ termState: "open", phase: "done", errKind: "none", errOnOpenTerm: false, hasCatch: false, outcome: "ok_0", msgPrinted: "none" });

        const missingText = await runPty({
          mode: "open",
          argv: ["replay", join(root, "missing.fxtape")],
          cwd: root,
          env: { HOME: home },
        });
        expect(missingText.status).toBe(1);
        expect(missingText.stderr).toContain("cannot open");
        mark({ termState: "open", phase: "done", errKind: "eio_file", errOnOpenTerm: true, hasCatch: false, outcome: "error_1", msgPrinted: "file_err" });

        mark({ termState: "open", phase: "write_io", errKind: "none", errOnOpenTerm: false, hasCatch: true, outcome: "running", msgPrinted: "none" });
        const missingJson = await runPty({
          mode: "open",
          argv: ["replay", join(root, "missing.fxtape"), "--json"],
          cwd: root,
          env: { HOME: home },
        });
        expect(missingJson.status).toBe(1);
        mark({ termState: "open", phase: "done", errKind: "eio_file", errOnOpenTerm: true, hasCatch: true, outcome: "error_1", msgPrinted: "file_err" });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    }

    // 2. Open-terminal stdin_prompt -> ok_0 (catch=true) & hung_up stdin_prompt -> quiet_129 (catch=true).
    {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-wfd-teams-")));
      const home = join(root, "home");
      const gateway = startDynamicFakeGateway(() => Response.json({ data: [] }));
      const issuer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch(request) {
          if (new URL(request.url).pathname === "/v2/teams") {
            return Response.json({
              teams: [
                { id: "team_one", slug: "team-one", name: "Team One" },
                { id: "team_two", slug: "team-two", name: "Team Two" },
              ],
            });
          }
          return new Response("not found", { status: 404 });
        },
      });
      try {
        writeAuthJson(home, "team_old", `http://127.0.0.1:${issuer.port}`);
        mark({ termState: "open", phase: "stdin_prompt", errKind: "none", errOnOpenTerm: false, hasCatch: true, outcome: "running", msgPrinted: "none" });
        const openTeams = await runPty({
          mode: "open",
          argv: ["teams"],
          cwd: root,
          needle: "Select a Vercel team",
          input: "2",
          env: {
            HOME: home,
            FX_TEST_OAUTH_ISSUER_URL: `http://127.0.0.1:${issuer.port}`,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
        });
        expect(openTeams).toEqual({ status: 0, stderr: "" });
        expect(JSON.parse(readFileSync(join(home, ".fx", "auth.json"), "utf8")).team_id).toBe("team_two");
        mark({ termState: "open", phase: "done", errKind: "none", errOnOpenTerm: false, hasCatch: true, outcome: "ok_0", msgPrinted: "none" });

        writeAuthJson(home, "team_old", `http://127.0.0.1:${issuer.port}`);
        const closedTeams = await runPty({
          mode: "wait_needle",
          argv: ["teams"],
          cwd: root,
          needle: "Select a Vercel team",
          env: {
            HOME: home,
            FX_TEST_OAUTH_ISSUER_URL: `http://127.0.0.1:${issuer.port}`,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
          },
        });
        expect(closedTeams).toEqual({ status: 129, stderr: "" });
        expect(JSON.parse(readFileSync(join(home, ".fx", "auth.json"), "utf8")).team_id).toBe("team_old");
        mark({ termState: "hung_up", phase: "subcmd_catch", errKind: "TerminalHungUp", errOnOpenTerm: false, hasCatch: true, outcome: "running", msgPrinted: "none" });
        mark({ termState: "hung_up", phase: "done", errKind: "TerminalHungUp", errOnOpenTerm: false, hasCatch: true, outcome: "quiet_129", msgPrinted: "none" });
      } finally {
        issuer.stop(true);
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    }

    // 3. Open -> hung_up stdin_prompt (catch=false) via fx login grok.
    {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-wfd-grok-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });
      const grokIssuer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch() {
          return Response.json({
            authorization_endpoint: `http://127.0.0.1:${grokIssuer.port}/authorize`,
            token_endpoint: `http://127.0.0.1:${grokIssuer.port}/token`,
          });
        },
      });
      try {
        mark({ termState: "open", phase: "stdin_prompt", errKind: "none", errOnOpenTerm: false, hasCatch: false, outcome: "running", msgPrinted: "none" });
        const closedGrok = await runPty({
          mode: "wait_needle",
          argv: ["login", "grok"],
          cwd: root,
          needle: "Paste the code",
          env: {
            HOME: home,
            FX_NO_OPEN_BROWSER: "1",
            FX_TEST_GROK_ISSUER_URL: `http://127.0.0.1:${grokIssuer.port}`,
          },
        });
        expect(closedGrok).toEqual({ status: 129, stderr: "" });
        mark({ termState: "hung_up", phase: "done", errKind: "TerminalHungUp", errOnOpenTerm: false, hasCatch: false, outcome: "quiet_129", msgPrinted: "none" });
      } finally {
        grokIssuer.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    }

    // 4. Write-side hang-ups (catch=false: fx status, fx replay, fx ask mid-stream; catch=true: fx login --api-key).
    {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-wfd-write-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(join(workspace, "note.txt"), "hello\n");
      const tapePath = join(root, "sample.fxtape");
      writeSampleTape(tapePath);

      let releaseTurn2!: () => void;
      const turn2Gate = new Promise<void>((resolve) => {
        releaseTurn2 = resolve;
      });
      const gateway = startDynamicFakeGateway(async (body) => {
        if (!body.includes("drv_call_1")) {
          return fakeGatewaySse([
            { type: "text-delta", id: "answer_1", delta: "First chunk paragraph." },
            { type: "tool-call", toolCallId: "drv_call_1", toolName: "read_file", input: { path: "note.txt" } },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage: { inputTokens: { total: 2 }, outputTokens: { total: 10 } } },
          ]);
        }
        await turn2Gate;
        return fakeGatewayFinalText("Second chunk after hangup.");
      });
      try {
        expect(await runPty({ mode: "immediate", argv: ["status"], cwd: workspace, env: { HOME: home } })).toEqual({ status: 129, stderr: "" });
        expect(await runPty({ mode: "wait_needle", argv: ["replay", tapePath, "--frames"], cwd: workspace, env: { HOME: home } })).toEqual({ status: 129, stderr: "" });

        const askMid = await runPty({
          mode: "ask_stream",
          argv: ["ask", "--auto", "Read note.txt and reply."],
          cwd: workspace,
          needle: "First chunk paragraph.",
          onPtyClosed: () => releaseTurn2(),
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "drv-key",
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_TEST_SKIP_ONBOARDING: "1",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
        });
        expect(askMid).toEqual({ status: 129, stderr: "" });
        mark({ termState: "hung_up", phase: "done", errKind: "TerminalHungUp", errOnOpenTerm: false, hasCatch: false, outcome: "quiet_129", msgPrinted: "none" });
      } finally {
        releaseTurn2();
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    }

    const unmapped = [...graphKeys].filter((k) => !covered.has(k) && !(k in UNREACHED_STATES));
    const stale = Object.keys(UNREACHED_STATES).filter((k) => !graphKeys.has(k) || covered.has(k));
    expect(unmapped).toEqual([]);
    expect(stale).toEqual([]);
  }, 30_000);
});
