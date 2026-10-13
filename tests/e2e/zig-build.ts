import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// The first `zig build` against an empty cache compiles Zig's build runner,
// which can take longer than a single test's timeout.
export const ZIG_BUILD_WARMUP_TIMEOUT_MS = 300_000;

// Resolves the global cache the way `zig` does for this process, so a test
// that isolates HOME can keep reusing it.
export function zigGlobalCacheDir(): string {
  if (process.env.ZIG_GLOBAL_CACHE_DIR) return process.env.ZIG_GLOBAL_CACHE_DIR;
  if (process.env.XDG_CACHE_HOME) return join(process.env.XDG_CACHE_HOME, "zig");
  return join(homedir(), ".cache", "zig");
}

// Compiles the MCP stdio dispatcher driver so each test's
// `zig build run-mcp-stdio-dispatcher-e2e` only runs it.
export function buildMcpDispatcherDriver(repoRoot: string): void {
  const result = spawnSync("zig", ["build", "build-mcp-stdio-dispatcher-e2e"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "ignore", "pipe"],
  });
  if (result.status !== 0) {
    throw new Error(
      `zig build build-mcp-stdio-dispatcher-e2e failed (${result.status ?? result.signal}):\n${result.stderr}`,
    );
  }
}
