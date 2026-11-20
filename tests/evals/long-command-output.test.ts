import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { assertToolNotUsed, cleanupWorkDir, createWorkDir, runEval } from "./eval-helpers";

const TIMEOUT = 240_000;
const CLI_TIMEOUT = 180;
// Unique to the build's last line, so the answer can only come from there.
const FAILURE_DETAIL = "checksum mismatch in bundle-7f3a";

let workDir: string | null = null;

afterEach(() => {
  if (workDir) {
    cleanupWorkDir(workDir);
    workDir = null;
  }
});

describe("eval: long command output", () => {
  test(
    "reports the last line of a failing build that prints past the output limit",
    async () => {
      workDir = createWorkDir();

      const result = await runEval(
        "Run ./build.sh once. It fails. Quote the exact last line it printed, which names the failing step.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
          setup: async (dir: string) => {
            // About 100 KB of steps, more than the 64 KiB a running command
            // keeps, then the line that says why the build stopped.
            const script = join(dir, "build.sh");
            writeFileSync(
              script,
              "#!/bin/sh\ni=0\nwhile [ $i -lt 1000 ]; do\n" +
                `  printf 'step %04d compiled module %s\\n' "$i" "${"x".repeat(72)}"\n` +
                "  i=$((i+1))\ndone\n" +
                `printf '%s\\n' 'step 1000 stopped the build: ${FAILURE_DETAIL}'\n` +
                "exit 1\n",
            );
            chmodSync(script, 0o755);
          },
        },
      );

      const builds = (result.json.tool_calls ?? []).filter((call) =>
        call.name === "shell" && /build\.sh/.test(call.command_result?.command ?? "")
      );
      expect(builds.length, "expected exactly one shell run of ./build.sh").toBe(1);
      // The last line must be in the first shell result, so the model must
      // not need to read the full output again.
      assertToolNotUsed(result, "read_tool_result");
      expect(result.json.output).toContain(FAILURE_DETAIL);
    },
    TIMEOUT,
  );
});
