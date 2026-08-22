import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  LIFECYCLE_TASK_PROMPT,
  prepareHeldOutLifecycleWorkspace,
  runBunTestFile,
  writeHeldOutLifecycleVerifier,
  writeLifecycleFixture,
} from "./composed-lifecycle-eval";


describe("composed lifecycle fixture", () => {
  test("frozen flaw passes visible tests and fails the held-out transition", async () => {
    const dir = mkdtempSync(join(tmpdir(), "fx-lifecycle-flawed-"));
    try {
      writeLifecycleFixture(dir, "flawed");
      expect(existsSync(join(dir, "held-out-lifecycle.test.ts"))).toBe(false);
      expect(statSync(dir).mode & 0o777).toBe(0o700);

      const visible = await runBunTestFile(dir, "pool.test.ts");
      expect(visible.code).toBe(0);

      writeHeldOutLifecycleVerifier(dir);
      const heldOut = await runBunTestFile(dir, "held-out-lifecycle.test.ts");
      expect(heldOut.code).not.toBe(0);
      expect(heldOut.stdout + heldOut.stderr).toContain("cleanupCompleted");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("known-correct implementation passes the held-out transition", async () => {
    const dir = mkdtempSync(join(tmpdir(), "fx-lifecycle-correct-"));
    try {
      writeLifecycleFixture(dir, "correct");
      const visible = await runBunTestFile(dir, "pool.test.ts");
      expect(visible.code).toBe(0);

      writeHeldOutLifecycleVerifier(dir);
      const heldOut = await runBunTestFile(dir, "held-out-lifecycle.test.ts");
      expect(heldOut.code).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("held-out verifier ignores agent-controlled Bun configuration", async () => {
    const agentDir = mkdtempSync(join(tmpdir(), "fx-lifecycle-agent-"));
    const verifierDir = mkdtempSync(join(tmpdir(), "fx-lifecycle-verifier-"));
    try {
      writeLifecycleFixture(agentDir, "flawed");
      writeFileSync(join(agentDir, "bunfig.toml"), "[test]\npreload = [\"./preload.ts\"]\n");
      writeFileSync(join(agentDir, "preload.ts"), "throw new Error(\"agent preload ran\");\n");

      prepareHeldOutLifecycleWorkspace(agentDir, verifierDir);

      expect(existsSync(join(verifierDir, "bunfig.toml"))).toBe(false);
      const heldOut = await runBunTestFile(
        verifierDir,
        "held-out-lifecycle.test.ts",
      );
      expect(heldOut.code).not.toBe(0);
      expect(heldOut.stdout + heldOut.stderr).not.toContain("agent preload ran");
    } finally {
      rmSync(agentDir, { recursive: true, force: true });
      rmSync(verifierDir, { recursive: true, force: true });
    }
  });

  test("held-out verifier rejects symlinked agent source", () => {
    const agentDir = mkdtempSync(join(tmpdir(), "fx-lifecycle-agent-"));
    const verifierDir = mkdtempSync(join(tmpdir(), "fx-lifecycle-verifier-"));
    try {
      writeLifecycleFixture(agentDir, "flawed");
      const externalPath = join(agentDir, "external.ts");
      writeFileSync(externalPath, "export const exposed = true;\n");
      rmSync(join(agentDir, "pool.ts"));
      symlinkSync(externalPath, join(agentDir, "pool.ts"));

      expect(() =>
        prepareHeldOutLifecycleWorkspace(agentDir, verifierDir)
      ).toThrow(/regular file/);
    } finally {
      rmSync(agentDir, { recursive: true, force: true });
      rmSync(verifierDir, { recursive: true, force: true });
    }
  });

  test("agent prompt stays generic and does not expose the held-out implementation", () => {
    expect(LIFECYCLE_TASK_PROMPT).toContain("asynchronous cleanup has settled");
    expect(LIFECYCLE_TASK_PROMPT).not.toMatch(/asyncio|python|semaphore|sigint/i);
    expect(LIFECYCLE_TASK_PROMPT).not.toContain("held-out-lifecycle.test.ts");
  });
});
