import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// Whether this process can write into a folder whose mode forbids it, as root
/// or a sandbox that holds every capability can.
export function ignoresFileModes(): boolean {
  const probe = mkdtempSync(join(tmpdir(), "fx-e2e-mode-probe-"));
  try {
    chmodSync(probe, 0o500);
    try {
      writeFileSync(join(probe, "probe"), "");
      return true;
    } catch {
      return false;
    }
  } finally {
    chmodSync(probe, 0o700);
    rmSync(probe, { recursive: true, force: true });
  }
}
