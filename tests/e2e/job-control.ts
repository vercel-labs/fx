/**
 * fx under an interactive shell in tmux, for job control: Ctrl+Z, bg, and fg
 * reach fx only when a shell with job control started it.
 */
import { execFileSync } from "node:child_process";
import type { TmuxSession } from "./tmux-helpers";

/// The shell to run in the pane: an interactive bash, with job control and no
/// startup files.
export const JOB_SHELL = "/bin/bash --noprofile --norc -i";

/// The variables the shell needs on top of fx's own: a plain prompt, and no
/// macOS notice that the default shell is zsh.
export const JOB_SHELL_ENV = { PS1: "$ ", BASH_SILENCE_DEPRECATION_WARNING: "1" };

function quote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

/// The line that starts `bin` from the shell, with its stderr in `stderrPath`.
/// With `ignoreJobSignals`, fx starts with SIGTTIN and SIGTTOU ignored, as a
/// parent that ignores them leaves it, so it can run in the background.
export function launchLine(bin: string, stderrPath: string, ignoreJobSignals = false): string {
  return ignoreJobSignals
    ? `/bin/sh -c "trap '' TTIN TTOU; exec ${quote(bin)}" 2>${quote(stderrPath)}`
    : `${quote(bin)} 2>${quote(stderrPath)}`;
}

/// The fx process on the session's terminal, with its ps state, or null when
/// none is running there. The state starts with "T" while fx is stopped and
/// has a "+" while fx is in the terminal's foreground.
export function fxOnTerminal(session: TmuxSession, bin: string): { pid: number; state: string } | null {
  const tty = execFileSync("ps", ["-o", "tty=", "-p", String(session.processPid())], { encoding: "utf8" }).trim();
  const out = execFileSync("ps", ["-t", tty, "-o", "pid=,stat=,command="], { encoding: "utf8" });
  for (const line of out.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/);
    if (match && (match[3] === bin || match[3].startsWith(`${bin} `))) {
      return { pid: Number(match[1]), state: match[2] };
    }
  }
  return null;
}

export const stopped = (state: string | null) => state !== null && state.startsWith("T");
export const inForeground = (state: string | null) => state !== null && !state.startsWith("T") && state.includes("+");

/// Waits until fx's state on the session's terminal passes `accept` and keeps
/// passing it for `steadyMs`, and returns that state.
export async function waitForFxState(
  session: TmuxSession,
  bin: string,
  accept: (state: string | null) => boolean,
  timeoutMs: number,
  steadyMs = 0,
): Promise<string | null> {
  const deadline = Date.now() + timeoutMs;
  let last: string | null = null;
  let since: number | null = null;
  while (Date.now() < deadline) {
    last = fxOnTerminal(session, bin)?.state ?? null;
    if (!accept(last)) since = null;
    else if (since === null) since = Date.now();
    if (since !== null && Date.now() - since >= steadyMs) return last;
    await Bun.sleep(25);
  }
  throw new Error(`fx never reached the state the test waits for; last state: ${last ?? "not running"}`);
}
