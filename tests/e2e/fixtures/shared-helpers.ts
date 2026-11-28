import { expect } from "bun:test";
import { chmodSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Writes an executable `#!/bin/sh` script under `<home>/helpers` and returns its path. */
export function installCommandHelper(home: string, name: string, scriptBody: string): string {
  const dir = join(home, "helpers");
  mkdirSync(dir, { recursive: true });
  const scriptPath = join(dir, name);
  writeFileSync(scriptPath, `#!/bin/sh\n${scriptBody}\n`);
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

/** Every regular file under `dir`, at any depth. */
export function collectFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...collectFiles(full));
    else if (st.isFile()) out.push(full);
  }
  return out;
}

/** Polls `check` until it passes or `timeoutMs` ends. Returns whether it passed. */
export async function waitForCondition(check: () => boolean, timeoutMs: number, stepMs = 25): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await Bun.sleep(stepMs);
  }
  return check();
}

/** Runs the system git in `cwd` and fails the test when it exits nonzero. Returns its stdout. */
export function runGit(cwd: string, args: string[]) {
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
