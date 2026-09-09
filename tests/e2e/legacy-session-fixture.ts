import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { REPO_ROOT, runFxFixtureBinary } from "../evals/eval-helpers";

let legacyBinary: Promise<string> | undefined;

export function ensureLegacyFixtureBinary(): Promise<string> {
  return legacyBinary ??= promisify(execFile)("bash", [
    join(REPO_ROOT, "scripts/legacy-session-fixture.sh"),
  ], { timeout: 600_000, maxBuffer: 4 * 1024 * 1024 })
    .then(({ stdout }) => stdout.trim());
}

export async function runLegacyFx(
  args: string[],
  opts: Parameters<typeof runFxFixtureBinary>[2] = {},
) {
  return runFxFixtureBinary(await ensureLegacyFixtureBinary(), args, opts);
}
