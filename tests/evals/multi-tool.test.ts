import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertFileContains,
  assertToolUsed,
  cleanupWorkDir,
  createWorkDir,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 600_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

describe("eval: multi-tool workflow", () => {
  test(
    "reads, edits, and runs a project",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Read the file src/greet.js, change the greeting from 'Hello' to 'Goodbye', then run `node src/greet.js` to verify it works. Tell me the output.",
        {
          cwd: workDir,
          timeoutSec: 120,
          setup: async (dir) => {
            mkdirSync(join(dir, "src"), { recursive: true });
            writeFileSync(
              join(dir, "src", "greet.js"),
              'const greeting = "Hello";\nconsole.log(`${greeting}, World!`);\n',
            );
          },
        },
      );

      assertFileContains(workDir, "src/greet.js", "Goodbye");
      assertToolUsed(result, "read_file");
      assertToolUsed(result, "edit_file");
      assertToolUsed(result, "shell");
      expect(result.json.output).toContain("Goodbye");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
