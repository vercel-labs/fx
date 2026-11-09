// Run context for the Bun drivers written as `bun test` files: which fx
// checkout and binary they drive, where their output goes, and the E2E helpers
// they borrow from tests/e2e/.
//
//   FX_WORKTREE    checkout under test (default: this one)
//   FX_BIN         binary under test (default: <checkout>/zig-out/bin/fx)
//   FX_TLA_OUT     output root (default: a folder under the system temp dir)
//   FX_TLA_REPEAT  how many times a repeatable check runs (default: 1)
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { REPO_ROOT, outDir } from "./tlc";

export const worktree = resolve(process.env.FX_WORKTREE ?? REPO_ROOT);
export const binary = process.env.FX_BIN ?? join(worktree, "zig-out", "bin", "fx");
export const artifacts = outDir(process.env.FX_TLA_CASE ?? "driver");
export const repetitions = Number(process.env.FX_TLA_REPEAT ?? "1");

/// The checkout's tests/e2e/tmux-helpers.ts: tmux sessions and fake gateways.
export async function targetHelpers() {
  return await targetModule("tmux-helpers.ts");
}

/// A helper module from the checkout's tests/e2e/, such as shell-sessions.ts.
export async function targetModule(name: string) {
  const path = join(worktree, "tests", "e2e", name);
  if (!existsSync(path)) throw new Error(`missing ${path}`);
  return await import(pathToFileURL(path).href);
}

export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function hashFile(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/// A minimal environment for an fx process under test: no inherited
/// credentials, sound, keychain, upgrade check, or dotenv.
export function testEnvironment(values: Record<string, string>, inherited = process.env): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of ["PATH", "TERM", "COLORTERM", "LANG", "LC_ALL", "TMPDIR"]) {
    if (inherited[key]) result[key] = inherited[key]!;
  }
  return {
    ...result,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    ...values,
  };
}
