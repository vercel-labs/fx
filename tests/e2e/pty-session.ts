/**
 * fx on a pseudo-terminal this process owns, for tests that change the
 * terminal under fx while its other side stays open: revoke it, hang it up,
 * or watch how much CPU fx burns afterwards. tmux cannot do that, because it
 * closes its side as soon as the pane's terminal goes away.
 *
 * Bun.Terminal holds the master. fx gets the slave as stdin and stdout, but
 * not as its controlling terminal, so no SIGHUP reaches it: what the terminal
 * reports is all fx sees. A /bin/sh wrapper writes the slave's name to a file
 * and sends stderr to another, then runs fx through `env -i` with exactly the
 * variables the caller gives.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { dlopen, FFIType, ptr } from "bun:ffi";

export type PtyExit = { code: number | null; signal: string | null };

export type TerminalFlags = { input: number; output: number; local: number; control: number };

/// revoke(2) exists on macOS and the BSDs; Linux has none.
export function revokeAvailable(): boolean {
  return process.platform === "darwin";
}

let libSystem: { symbols: { revoke: (path: number) => number } } | null = null;

/// revoke(2) on a terminal device such as /dev/ttys012: every open
/// descriptor for it stops working. Throws when the call fails.
export function revokeTerminal(path: string): void {
  libSystem ??= dlopen("/usr/lib/libSystem.B.dylib", {
    revoke: { args: [FFIType.ptr], returns: FFIType.i32 },
  }) as unknown as { symbols: { revoke: (path: number) => number } };
  const name = Buffer.from(`${path}\0`);
  const status = libSystem.symbols.revoke(ptr(name));
  if (status !== 0) throw new Error(`revoke(${path}) returned ${status}`);
}

const WRAPPER = 'tty > "$1" || exit 97; exec 2> "$2"; shift 2; exec "$@"';

export class PtySession {
  readonly pid: number;
  readonly stderrPath: string;
  readonly flagsBefore: TerminalFlags;
  private readonly terminal: Bun.Terminal;
  private readonly proc: Bun.Subprocess;
  private readonly ttyPath: string;
  private text = "";
  private lastOutputAt = Date.now();
  private exit: PtyExit | null = null;
  private masterOpen = true;

  private constructor(
    terminal: Bun.Terminal,
    proc: Bun.Subprocess,
    ttyPath: string,
    stderrPath: string,
    flagsBefore: TerminalFlags,
  ) {
    this.terminal = terminal;
    this.proc = proc;
    this.pid = proc.pid;
    this.ttyPath = ttyPath;
    this.stderrPath = stderrPath;
    this.flagsBefore = flagsBefore;
    void proc.exited.then(() => {
      this.exit = { code: proc.exitCode, signal: proc.signalCode ?? null };
    });
  }

  /// Starts `bin` on a new PTY with only the variables in `env`. `dir` is a
  /// private folder for the wrapper's files.
  static async launch(opts: {
    bin: string;
    args?: string[];
    env: Record<string, string>;
    cwd: string;
    dir: string;
    cols?: number;
    rows?: number;
  }): Promise<PtySession> {
    let session: PtySession | null = null;
    const pending: string[] = [];
    const decoder = new TextDecoder();
    const terminal = new Bun.Terminal({
      cols: opts.cols ?? 100,
      rows: opts.rows ?? 30,
      data(_terminal, chunk) {
        const text = typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });
        if (session) {
          session.text += text;
          session.lastOutputAt = Date.now();
        } else pending.push(text);
      },
    });
    const flagsBefore = flagsOf(terminal);
    const ttyFile = join(opts.dir, "tty");
    const stderrPath = join(opts.dir, "stderr.log");
    const assignments = Object.entries(opts.env).map(([key, value]) => `${key}=${value}`);
    const proc = Bun.spawn(
      ["/bin/sh", "-c", WRAPPER, "sh", ttyFile, stderrPath, "/usr/bin/env", "-i", ...assignments, opts.bin, ...(opts.args ?? [])],
      { cwd: opts.cwd, env: { PATH: "/usr/bin:/bin" }, terminal },
    );
    const deadline = Date.now() + 5_000;
    while (!existsSync(ttyFile) || readFileSync(ttyFile, "utf8").trim() === "") {
      if (Date.now() > deadline) throw new Error("the PTY wrapper never wrote its terminal name");
      await Bun.sleep(5);
    }
    session = new PtySession(terminal, proc, readFileSync(ttyFile, "utf8").trim(), stderrPath, flagsBefore);
    session.text = pending.join("");
    return session;
  }

  output(): string {
    return this.text;
  }

  stderr(): string {
    return existsSync(this.stderrPath) ? readFileSync(this.stderrPath, "utf8") : "";
  }

  /// Waits for output that `ready` accepts. Returns false on timeout or exit.
  async waitForOutput(ready: (output: string) => boolean, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (ready(this.text)) return true;
      if (this.exit) return ready(this.text);
      await Bun.sleep(10);
    }
    return ready(this.text);
  }

  /// Waits until fx has written nothing for `quietMs`, so it is idle in its
  /// input loop. Returns false on timeout or exit.
  async waitForQuietOutput(quietMs: number, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.exit) return false;
      if (Date.now() - this.lastOutputAt >= quietMs) return true;
      await Bun.sleep(10);
    }
    return false;
  }

  write(text: string): void {
    this.terminal.write(text);
  }

  /// revoke(2) on the slave: every open descriptor for it stops working.
  revoke(): void {
    revokeTerminal(this.ttyPath);
  }

  /// revoke(2) on the slave while fx is stopped, so the revoke lands between
  /// two of its polls rather than in one: a poll fx was waiting in restarts
  /// after SIGCONT and meets the revoked terminal.
  async revokeBetweenPolls(): Promise<void> {
    process.kill(this.pid, "SIGSTOP");
    await Bun.sleep(20);
    try {
      this.revoke();
    } finally {
      process.kill(this.pid, "SIGCONT");
    }
  }

  /// Closes the master: the terminal hangs up.
  hangUp(): void {
    if (!this.masterOpen) return;
    this.masterOpen = false;
    try {
      this.terminal.close();
    } catch {}
  }

  /// The terminal's settings now, read through the master.
  flagsNow(): TerminalFlags {
    return flagsOf(this.terminal);
  }

  /// fx's user and system CPU time so far, in seconds, or null once it is gone.
  cpuSeconds(): number | null {
    try {
      const text = execFileSync("ps", ["-o", "time=", "-p", String(this.pid)], { encoding: "utf8" }).trim();
      return text.split(":").reduce((total, part) => total * 60 + Number(part), 0);
    } catch {
      return null;
    }
  }

  exited(): PtyExit | null {
    return this.exit;
  }

  /// Waits up to `timeoutMs` for fx to exit; null when it is still running.
  async waitForExit(timeoutMs: number): Promise<PtyExit | null> {
    const deadline = Date.now() + timeoutMs;
    while (!this.exit && Date.now() < deadline) await Bun.sleep(10);
    return this.exit;
  }

  /// Kills fx if it is still running, waits for it, and closes the master.
  async dispose(): Promise<void> {
    if (!this.exit) {
      try {
        process.kill(this.pid, "SIGKILL");
      } catch {}
      await this.proc.exited;
    }
    this.hangUp();
  }
}

function flagsOf(terminal: Bun.Terminal): TerminalFlags {
  return {
    input: terminal.inputFlags,
    output: terminal.outputFlags,
    local: terminal.localFlags,
    control: terminal.controlFlags,
  };
}
