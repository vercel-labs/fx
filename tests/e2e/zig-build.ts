import { homedir } from "node:os";
import { join } from "node:path";

// Resolves the global cache the way `zig` does for this process, so a test
// that isolates HOME can keep reusing it.
export function zigGlobalCacheDir(): string {
  if (process.env.ZIG_GLOBAL_CACHE_DIR) return process.env.ZIG_GLOBAL_CACHE_DIR;
  if (process.env.XDG_CACHE_HOME) return join(process.env.XDG_CACHE_HOME, "zig");
  return join(homedir(), ".cache", "zig");
}
