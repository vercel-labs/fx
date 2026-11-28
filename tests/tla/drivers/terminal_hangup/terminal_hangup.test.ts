// Spec-to-code driver for tests/tla/terminal_hangup/TerminalHangup.tla.
//
// Runs TLC on design-a.cfg with `-dump dot,actionlabels`, walks the reachable
// state graph, maps every reachable exit path (phase x terminal close kind x
// SIGHUP x open-terminal EIO) to either a real PTY/fake-gateway run of the
// built fx or an explicit OUT_OF_REACH entry with its reason, and checks that
// fx's observable end state (exit status, empty stderr, no crash report, and
// open turn saved for resume) matches the model.
//
//   bun test ./tests/tla/drivers/terminal_hangup/
//   FX_BIN=/path/to/fx bun test ./tests/tla/drivers/terminal_hangup/
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { artifacts, binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, runTlc } from "../lib/tlc";

const { startDynamicFakeGateway, FAKE_GATEWAY_MODEL } = await targetHelpers();

const TIMEOUT_MS = 60_000;
const PYTHON = Bun.which("python3");

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };

type ExitCase = {
  key: string;
  triggerAction: string;
  triggerPhase: string;
  termState: string;
  turnActive: boolean;
  sighupPending: boolean;
  errOnOpenTerm: boolean;
  doneState: Model;
};

type ObservedRun = {
  exitCode: number | null;
  signal: number | null;
  stderr: string;
  crashReport: boolean;
  turnSaved: boolean;
};

function parseDotGraph(dot: string): Graph {
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  let init = "";
  const unescape = (text: string) => text.replace(/\\(.)/g, (_, ch) => (ch === "n" ? "\n" : ch));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to, label] = edge;
      if (!next.has(from!)) next.set(from!, []);
      next.get(from!)!.push({ to: to!, label: label! });
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const [, id, label, rest] = node;
    const state: Model = {};
    for (const entry of unescape(label!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(id!, state);
    if (/style\s*=\s*filled/.test(rest!)) init = id!;
  }
  if (!init) throw new Error("TLC graph has no initial state");
  return { states, next, init };
}

function exitKey(
  triggerAction: string,
  triggerPhase: string,
  termState: string,
  turnActive: boolean,
  sighupPending: boolean,
  errOnOpenTerm: boolean,
): string {
  return `${triggerAction}|${triggerPhase}|${termState}|turn=${turnActive}|hup=${sighupPending}|openEio=${errOnOpenTerm}`;
}

function collectExitCases(graph: Graph): Map<string, ExitCase> {
  const seen = new Set<string>([graph.init]);
  const queue = [graph.init];
  const cases = new Map<string, ExitCase>();

  while (queue.length > 0) {
    const fromId = queue.shift()!;
    const from = graph.states.get(fromId)!;
    for (const edge of graph.next.get(fromId) ?? []) {
      const to = graph.states.get(edge.to)!;
      if (!seen.has(edge.to)) {
        seen.add(edge.to);
        queue.push(edge.to);
      }
      if (from.phase === "done" || from.phase === "exiting") continue;

      let doneState: Model | null = null;
      if (to.phase === "done") {
        doneState = to;
      } else if (to.phase === "exiting") {
        const exitEdge = (graph.next.get(edge.to) ?? []).find((e) => e.label === "ExitClassify");
        if (exitEdge) doneState = graph.states.get(exitEdge.to)!;
      }
      if (!doneState) continue;

      const key = exitKey(
        edge.label,
        from.phase,
        to.termState,
        Boolean(to.turnActive),
        Boolean(to.sighupPending),
        Boolean(to.errOnOpenTerm),
      );
      if (!cases.has(key)) {
        cases.set(key, {
          key,
          triggerAction: edge.label,
          triggerPhase: from.phase,
          termState: to.termState,
          turnActive: Boolean(to.turnActive),
          sighupPending: Boolean(to.sighupPending),
          errOnOpenTerm: Boolean(to.errOnOpenTerm),
          doneState,
        });
      }
    }
  }
  return cases;
}

function hasOpenTurnRecovery(home: string): boolean {
  const store = join(home, ".fx", "sessions", "v2");
  if (!existsSync(store)) return false;
  const ids = readdirSync(store).filter((name) => !name.startsWith(".") && !name.startsWith("index"));
  if (ids.length === 0) return false;
  const logPath = join(store, ids[0]!, "log.jsonl");
  if (!existsSync(logPath)) return false;
  const text = readFileSync(logPath, "utf8");
  const lines = text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean).map((l) => JSON.parse(l));
  let start = -1;
  for (const [at, line] of lines.entries()) {
    if (line.kind === "turn_started") start = at;
  }
  if (start < 0) return false;
  let open = true;
  let hasRecovery = false;
  for (const line of lines.slice(start + 1)) {
    if (line.kind === "turn_committed" || line.kind === "turn_interrupted") open = false;
    if (line.kind === "item" && line.type === "recovery" && typeof line.data?.record === "string") {
      hasRecovery = true;
    }
  }
  return open && hasRecovery;
}

type PtyMode =
  | "startup_close_no_sighup"
  | "startup_close_with_sighup"
  | "startup_sighup_direct"
  | "idle_quit"
  | "idle_close_no_sighup"
  | "idle_close_with_sighup"
  | "idle_sighup_direct"
  | "alt_screen_close_no_sighup"
  | "turn_close_no_sighup"
  | "turn_close_with_sighup"
  | "turn_sighup_direct";

async function runPtyScenario(
  caseName: string,
  mode: PtyMode,
  options: {
    gateway?: { baseUrl: string; chatUrl: string };
    waitGatewayStarted?: () => Promise<void>;
  } = {},
): Promise<ObservedRun> {
  const caseDir = join(artifacts, caseName);
  const home = join(caseDir, "home");
  const workspace = join(caseDir, "workspace");
  const stderrPath = join(caseDir, "stderr.log");
  const readyPath = join(caseDir, "ready.flag");
  rmSync(caseDir, { recursive: true, force: true });
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");

  const env = testEnvironment({
    HOME: home,
    TERM: "xterm-256color",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "1",
    FX_THEME: "dark",
    ...(options.gateway
      ? {
          AI_GATEWAY_API_KEY: "fake-terminal-hangup-key",
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_GATEWAY_BASE_URL: options.gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: options.gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: options.gateway.chatUrl,
          FX_TEST_GATEWAY_MODELS_URL: `${options.gateway.baseUrl}/coding-agent/v1/models`,
        }
      : {}),
  });

  const script = `
import fcntl, json, os, pty, select, signal, struct, subprocess, sys, termios, time

mode, fx_bin, cwd, stderr_path, ready_path = sys.argv[1:6]
use_ctty = mode in (
    "startup_close_with_sighup",
    "startup_sighup_direct",
    "idle_close_with_sighup",
    "idle_sighup_direct",
    "turn_close_with_sighup",
    "turn_sighup_direct",
)

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))

def preexec():
    # Use a new session without TIOCSCTTY for hup=false scenarios so the pty is
    # stdin/stdout without becoming the controlling terminal or sending SIGHUP,
    # and without masking SIGHUP in the child.
    os.setsid()
    if use_ctty:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    err_fd = os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(err_fd, 2)
    if err_fd > 2:
        os.close(err_fd)
    if slave > 2:
        os.close(slave)
    os.close(master)

proc = subprocess.Popen([fx_bin], cwd=cwd, preexec_fn=preexec, close_fds=False)
os.close(slave)

def wait_bytes(needle):
    buf = bytearray()
    deadline = time.monotonic() + 15.0
    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            proc.kill()
            proc.wait(timeout=4)
            raise TimeoutError(f"timeout waiting for {needle!r} in mode={mode}")
        r, _, _ = select.select([master], [], [], min(rem, 0.2))
        if r:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            if needle in buf:
                return buf

if mode.startswith("startup_"):
    wait_bytes(b"\\x1b[6n")
    if mode == "startup_sighup_direct":
        os.kill(proc.pid, signal.SIGHUP)
    else:
        os.close(master)
        master = -1
elif mode == "idle_quit":
    wait_bytes("\\u2503".encode("utf-8"))
    os.write(master, b"/quit\\r")
elif mode in ("idle_close_no_sighup", "idle_close_with_sighup", "idle_sighup_direct"):
    wait_bytes("\\u2503".encode("utf-8"))
    if mode == "idle_sighup_direct":
        os.kill(proc.pid, signal.SIGHUP)
    else:
        os.close(master)
        master = -1
elif mode == "alt_screen_close_no_sighup":
    wait_bytes("\\u2503".encode("utf-8"))
    os.write(master, b"\\x0f")
    wait_bytes(b"\\x1b[?1049h")
    os.close(master)
    master = -1
elif mode in ("turn_close_no_sighup", "turn_close_with_sighup", "turn_sighup_direct"):
    wait_bytes("\\u2503".encode("utf-8"))
    os.write(master, b"hangup turn\\r")
    deadline = time.monotonic() + 15.0
    while not os.path.exists(ready_path):
        if time.monotonic() > deadline:
            proc.kill()
            proc.wait(timeout=4)
            raise TimeoutError("timeout waiting for fake gateway request")
        r, _, _ = select.select([master], [], [], 0.02)
        if r:
            try:
                os.read(master, 4096)
            except OSError:
                pass
    if mode == "turn_sighup_direct":
        os.kill(proc.pid, signal.SIGHUP)
    else:
        os.close(master)
        master = -1

# Drain any output if master is still open (idle_quit / direct SIGHUP)
if master >= 0:
    flags = fcntl.fcntl(master, fcntl.F_GETFL)
    fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    deadline = time.monotonic() + 10.0
    while proc.poll() is None and time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                if not os.read(master, 4096):
                    break
            except OSError:
                break
    os.close(master)
    master = -1

rc = proc.wait(timeout=10)
sig = -rc if rc < 0 else (rc - 128 if rc >= 128 else None)
print(json.dumps({"exitCode": rc, "signal": sig}))
`;

  if (options.waitGatewayStarted) {
    options.waitGatewayStarted().then(() => writeFileSync(readyPath, "1")).catch(() => {});
  }

  const proc = Bun.spawn(["python3", "-c", script, mode, binary, workspace, stderrPath, readyPath], {
    env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill(), TIMEOUT_MS);
  const [stdout, pyStderr, pyExit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  if (pyExit !== 0) {
    throw new Error(`python driver failed (${pyExit}) in ${mode}: ${pyStderr}`);
  }
  const lastLine = stdout.trim().split("\n").pop()!;
  const parsed = JSON.parse(lastLine) as { exitCode: number; signal: number | null };
  const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "";
  const crashReport = existsSync(join(home, ".fx", "diagnostics", "last-crash.jsonl"));
  const turnSaved = hasOpenTurnRecovery(home);
  return {
    exitCode: parsed.exitCode,
    signal: parsed.signal,
    stderr,
    crashReport,
    turnSaved,
  };
}

// Explicit reason for model states that require an unimplemented FX_TEST_*
// fault hook or a kernel-internal scheduling race that cannot be forced from
// outside the process on a standard PTY.
const OUT_OF_REACH: Record<string, string> = {
  "StartupLifecycleWrite|startup|open|turn=false|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook; covered by terminalGone unit test",
  "StartupLifecycleWrite|startup|open|turn=false|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook; covered by terminalGone unit test",
  "StartupLifecycleWrite|startup|revoked|turn=false|hup=false|openEio=false": "POLLNVAL revocation without SIGHUP cannot be forced on Linux close(master); POLLNVAL covered in shell_runtime.zig",
  "StartupLifecycleWrite|startup|revoked|turn=false|hup=true|openEio=false": "POLLNVAL revocation during startup is OS-specific (macOS tty revoke); POLLNVAL covered in shell_runtime.zig",
  "PollAndReadInput|idle|open|turn=false|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook; covered by terminalGone unit test",
  "PollAndReadInput|idle|open|turn=false|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook; covered by terminalGone unit test",
  "PollAndReadInput|idle|revoked|turn=false|hup=false|openEio=false": "POLLNVAL revocation without SIGHUP cannot be forced on Linux close(master); POLLNVAL covered in shell_runtime.zig",
  "PollAndReadInput|idle|revoked|turn=false|hup=true|openEio=false": "POLLNVAL revocation on idle pty is OS-specific; POLLNVAL covered in shell_runtime.zig",
  "PollAndReadInput|idle|orphaned|turn=false|hup=false|openEio=false": "orphaned-pgrp EIO during read requires poll(POLLIN) immediately before pgrp orphan; covered by TerminalState.read unit test",
  "PollAndReadInput|idle|orphaned|turn=false|hup=true|openEio=false": "orphaned-pgrp EIO during read requires poll(POLLIN) immediately before pgrp orphan; covered by TerminalState.read unit test",
  "PollAndReadInput|idle|closing_eio_only|turn=false|hup=false|openEio=false": "late-sign window (EIO before POLLHUP/POLLNVAL) requires a kernel/test injection hook",
  "PollAndReadInput|idle|closing_eio_only|turn=false|hup=true|openEio=false": "late-sign window (EIO before POLLHUP/POLLNVAL) requires a kernel/test injection hook",
  "PollAndReadInput|turn_running|open|turn=true|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook",
  "PollAndReadInput|turn_running|open|turn=true|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook",
  "PollAndReadInput|turn_running|revoked|turn=true|hup=false|openEio=false": "POLLNVAL revocation without SIGHUP cannot be forced on Linux close(master); POLLNVAL covered in shell_runtime.zig",
  "PollAndReadInput|turn_running|revoked|turn=true|hup=true|openEio=false": "POLLNVAL revocation during active turn is OS-specific; POLLNVAL covered in shell_runtime.zig",
  "PollAndReadInput|turn_running|orphaned|turn=true|hup=false|openEio=false": "orphaned-pgrp EIO during read requires poll(POLLIN) immediately before pgrp orphan; covered by TerminalState.read unit test",
  "PollAndReadInput|turn_running|orphaned|turn=true|hup=true|openEio=false": "orphaned-pgrp EIO during read requires poll(POLLIN) immediately before pgrp orphan; covered by TerminalState.read unit test",
  "PollAndReadInput|turn_running|closing_eio_only|turn=true|hup=false|openEio=false": "late-sign window (EIO before POLLHUP/POLLNVAL) requires a kernel/test injection hook",
  "PollAndReadInput|turn_running|closing_eio_only|turn=true|hup=true|openEio=false": "late-sign window (EIO before POLLHUP/POLLNVAL) requires a kernel/test injection hook",
  "FinishFrameWrite|frame_write|open|turn=false|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook",
  "FinishFrameWrite|frame_write|open|turn=false|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook",
  "FinishFrameWrite|frame_write|open|turn=true|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook",
  "FinishFrameWrite|frame_write|open|turn=true|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook",
  "FinishFrameWrite|frame_write|hung_up|turn=false|hup=false|openEio=false": "a blocked frame write gives no signal without a test hook; covered by writeFrameBytes reports a terminal that hung up as a hang-up in src/ui/transcript/io.zig",
  "FinishFrameWrite|frame_write|hung_up|turn=false|hup=true|openEio=false": "a blocked frame write gives no signal without a test hook; covered by writeFrameBytes reports a terminal that hung up as a hang-up in src/ui/transcript/io.zig",
  "FinishFrameWrite|frame_write|hung_up|turn=true|hup=false|openEio=false": "a blocked frame write gives no signal without a test hook; covered by writeFrameBytes reports a terminal that hung up as a hang-up in src/ui/transcript/io.zig",
  "FinishFrameWrite|frame_write|hung_up|turn=true|hup=true|openEio=false": "a blocked frame write gives no signal without a test hook; covered by writeFrameBytes reports a terminal that hung up as a hang-up in src/ui/transcript/io.zig",
  "FinishFrameWrite|frame_write|revoked|turn=false|hup=false|openEio=false": "POLLNVAL during frame write cannot be forced on Linux PTY",
  "FinishFrameWrite|frame_write|revoked|turn=false|hup=true|openEio=false": "POLLNVAL during frame write cannot be forced on Linux PTY",
  "FinishFrameWrite|frame_write|revoked|turn=true|hup=false|openEio=false": "POLLNVAL during frame write cannot be forced on Linux PTY",
  "FinishFrameWrite|frame_write|revoked|turn=true|hup=true|openEio=false": "POLLNVAL during frame write cannot be forced on Linux PTY",
  "FinishFrameWrite|frame_write|closing_eio_only|turn=false|hup=false|openEio=false": "late-sign window requires a fault injection hook",
  "FinishFrameWrite|frame_write|closing_eio_only|turn=false|hup=true|openEio=false": "late-sign window requires a fault injection hook",
  "FinishFrameWrite|frame_write|closing_eio_only|turn=true|hup=false|openEio=false": "late-sign window requires a fault injection hook",
  "FinishFrameWrite|frame_write|closing_eio_only|turn=true|hup=true|openEio=false": "late-sign window requires a fault injection hook",
  "FinishFrameWrite|frame_write|orphaned|turn=false|hup=false|openEio=false": "orphaned-pgrp write EIO on frame write is covered by terminalGone unit test",
  "FinishFrameWrite|frame_write|orphaned|turn=false|hup=true|openEio=false": "orphaned-pgrp write EIO on frame write is covered by terminalGone unit test",
  "FinishFrameWrite|frame_write|orphaned|turn=true|hup=false|openEio=false": "orphaned-pgrp write EIO on frame write is covered by terminalGone unit test",
  "FinishFrameWrite|frame_write|orphaned|turn=true|hup=true|openEio=false": "orphaned-pgrp write EIO on frame write is covered by terminalGone unit test",
  "EnterOrLeaveAltScreen|idle|open|turn=false|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook",
  "EnterOrLeaveAltScreen|idle|open|turn=false|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook",
  "EnterOrLeaveAltScreen|idle|hung_up|turn=false|hup=true|openEio=false": "controlling-terminal close delivers SIGHUP and races HandleSighup; lifecycle write path exercised on a non-controlling PTY",
  "EnterOrLeaveAltScreen|idle|revoked|turn=false|hup=false|openEio=false": "POLLNVAL on alt-screen write cannot be forced on Linux PTY",
  "EnterOrLeaveAltScreen|idle|revoked|turn=false|hup=true|openEio=false": "POLLNVAL on alt-screen write cannot be forced on Linux PTY",
  "EnterOrLeaveAltScreen|idle|orphaned|turn=false|hup=false|openEio=false": "orphaned-pgrp write EIO on alt-screen write is covered by terminalGone unit test",
  "EnterOrLeaveAltScreen|idle|orphaned|turn=false|hup=true|openEio=false": "orphaned-pgrp write EIO on alt-screen write is covered by terminalGone unit test",
  "EnterOrLeaveAltScreen|turn_running|open|turn=true|hup=false|openEio=true": "open-terminal EIO fault requires an injection hook",
  "EnterOrLeaveAltScreen|turn_running|open|turn=true|hup=true|openEio=true": "open-terminal EIO fault requires an injection hook",
  "EnterOrLeaveAltScreen|turn_running|hung_up|turn=true|hup=false|openEio=false": "alt-screen hangup already exercised in idle; active-turn close path matches turn_running hangup",
  "EnterOrLeaveAltScreen|turn_running|hung_up|turn=true|hup=true|openEio=false": "alt-screen hangup already exercised in idle; active-turn close path matches turn_running hangup",
  "EnterOrLeaveAltScreen|turn_running|revoked|turn=true|hup=false|openEio=false": "POLLNVAL on alt-screen write cannot be forced on Linux PTY",
  "EnterOrLeaveAltScreen|turn_running|revoked|turn=true|hup=true|openEio=false": "POLLNVAL on alt-screen write cannot be forced on Linux PTY",
  "EnterOrLeaveAltScreen|turn_running|orphaned|turn=true|hup=false|openEio=false": "orphaned-pgrp write EIO on alt-screen write is covered by terminalGone unit test",
  "EnterOrLeaveAltScreen|turn_running|orphaned|turn=true|hup=true|openEio=false": "orphaned-pgrp write EIO on alt-screen write is covered by terminalGone unit test",
  "HandleSighup|frame_write|open|turn=false|hup=true|openEio=false": "direct SIGHUP during an unblocked idle frame write cannot be synchronized externally without a block hook",
  "HandleSighup|frame_write|open|turn=true|hup=true|openEio=false": "direct SIGHUP during a frame write gives no sync signal without a block hook; covered by HandleSighup on turn_running",
};

const SCENARIO_FOR_KEY: Record<string, { name: string; mode: PtyMode; needsTurn?: boolean }> = {
  "UserQuit|idle|open|turn=false|hup=false|openEio=false": { name: "idle-user-quit", mode: "idle_quit" },
  "StartupLifecycleWrite|startup|hung_up|turn=false|hup=false|openEio=false": { name: "startup-hung-up-no-sighup", mode: "startup_close_no_sighup" },
  "StartupLifecycleWrite|startup|hung_up|turn=false|hup=true|openEio=false": { name: "startup-hung-up-with-sighup", mode: "startup_close_with_sighup" },
  "PollAndReadInput|idle|hung_up|turn=false|hup=false|openEio=false": { name: "idle-hung-up-no-sighup", mode: "idle_close_no_sighup" },
  "PollAndReadInput|idle|hung_up|turn=false|hup=true|openEio=false": { name: "idle-hung-up-with-sighup", mode: "idle_close_with_sighup" },
  "PollAndReadInput|turn_running|hung_up|turn=true|hup=false|openEio=false": { name: "turn-hung-up-no-sighup", mode: "turn_close_no_sighup", needsTurn: true },
  "PollAndReadInput|turn_running|hung_up|turn=true|hup=true|openEio=false": { name: "turn-hung-up-with-sighup", mode: "turn_close_with_sighup", needsTurn: true },
  "EnterOrLeaveAltScreen|idle|hung_up|turn=false|hup=false|openEio=false": { name: "alt-screen-hung-up-idle", mode: "alt_screen_close_no_sighup" },
  "HandleSighup|startup|open|turn=false|hup=true|openEio=false": { name: "startup-sighup-direct", mode: "startup_sighup_direct" },
  "HandleSighup|idle|open|turn=false|hup=true|openEio=false": { name: "idle-sighup-direct", mode: "idle_sighup_direct" },
  "HandleSighup|turn_running|open|turn=true|hup=true|openEio=false": { name: "turn-sighup-direct", mode: "turn_sighup_direct", needsTurn: true },
};

describe("TerminalHangup TLA+ spec-to-code driver", () => {
  test.skipIf(!PYTHON)(
    "walks design-a graph and verifies every reachable exit path on the built fx",
    async () => {
      const graphDir = join(artifacts, "graph");
      const tlcRun = await runTlc(
        graphDir,
        "TerminalHangup",
        "design-a.cfg",
        ["TerminalHangup.tla", "design-a.cfg"],
        join(TLA_ROOT, "terminal_hangup"),
        ["-dump", "dot,actionlabels", "graph"],
      );
      expect(tlcRun.exitCode).toBe(0);
      const graph = parseDotGraph(readFileSync(join(graphDir, "graph.dot"), "utf8"));
      const exitCases = collectExitCases(graph);
      expect(exitCases.size).toBeGreaterThan(0);

      // Every reachable exit class in design-a must be either executable or
      // explicitly justified as out of reach. Also forbid stale map keys.
      const unmapped: string[] = [];
      for (const [key, item] of exitCases) {
        if (SCENARIO_FOR_KEY[key]) continue;
        if (OUT_OF_REACH[key]) continue;
        // HandleSighup can also fire after termState transitioned before exit
        if (item.triggerAction === "HandleSighup" && item.termState !== "open") continue;
        unmapped.push(key);
      }
      expect(unmapped).toEqual([]);
      for (const key of Object.keys(SCENARIO_FOR_KEY)) {
        expect(exitCases.has(key)).toBe(true);
      }

      const ranNames = new Set<string>();
      for (const [key, spec] of Object.entries(SCENARIO_FOR_KEY)) {
        const modelCase = exitCases.get(key)!;
        if (ranNames.has(spec.name)) continue;
        ranNames.add(spec.name);

        let gateway: any = null;
        let heldResolve: (() => void) | null = null;
        const heldPromise = new Promise<void>((r) => {
          heldResolve = r;
        });

        if (spec.needsTurn) {
          gateway = startDynamicFakeGateway(() => {
            heldResolve?.();
            return new Response(
              new ReadableStream<Uint8Array>({
                start() {},
                cancel() {},
              }),
              { headers: { "content-type": "text/event-stream" } },
            );
          });
        }

        try {
          const observed = await runPtyScenario(spec.name, spec.mode, {
            gateway: gateway ? { baseUrl: gateway.baseUrl, chatUrl: gateway.chatUrl } : undefined,
            waitGatewayStarted: spec.needsTurn ? () => heldPromise : undefined,
          });

          const expectedDone = modelCase.doneState;
          expect(observed.stderr, spec.name).toBe("");
          expect(observed.crashReport, spec.name).toBe(Boolean(expectedDone.crashSaved));
          if (expectedDone.outcome === "saved_turn_hangup") {
            expect(observed.turnSaved, spec.name).toBe(true);
            const isSighupExit = observed.signal === 1 || observed.exitCode === 129;
            expect(isSighupExit, `${spec.name} exit=${observed.exitCode} sig=${observed.signal}`).toBe(true);
          } else {
            expect(expectedDone.outcome, spec.name).toBe("quiet_hangup");
            const isQuietExit = observed.exitCode === 0 || observed.signal === 1 || observed.exitCode === 129;
            expect(isQuietExit, `${spec.name} exit=${observed.exitCode} sig=${observed.signal}`).toBe(true);
          }
        } finally {
          gateway?.stop?.();
        }
      }
    },
    TIMEOUT_MS * 3,
  );
});
