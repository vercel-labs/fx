import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx, XDG_ENV_KEYS } from "../evals/eval-helpers";

const TIMEOUT = 20_000;

// Captured at import time, before any test can touch the environment: this is what the bunfig
// preload left behind, and the suite depends on all four keys being gone.
const XDG_AT_LOAD = Object.fromEntries(
  XDG_ENV_KEYS.map((key) => [key, process.env[key]]),
);

const linuxTest = test.skipIf(process.platform !== "linux");
const macosTest = test.skipIf(process.platform !== "darwin");

function makeHome(): string {
  return mkdtempSync(join(tmpdir(), "fx-profile-layout-"));
}

function profileLine(stdout: string): string {
  const line = stdout.split("\n").find((entry) => entry.startsWith("[ok] profile: "));
  if (!line) throw new Error(`doctor printed no profile check:\n${stdout}`);
  return line.slice("[ok] profile: ".length).trim();
}

describe("profile layout", () => {
  test("the suite never inherits the host XDG environment", async () => {
    for (const key of XDG_ENV_KEYS) {
      expect(XDG_AT_LOAD[key]).toBeUndefined();
    }

    const home = makeHome();
    const hostState = mkdtempSync(join(tmpdir(), "fx-host-state-"));
    try {
      // A developer machine that exports a real state root must not receive a single write.
      process.env.XDG_STATE_HOME = hostState;
      const result = await runFx(["workspace", "add", home], {
        env: { HOME: home },
        timeoutMs: TIMEOUT,
      });

      expect(result.code).toBe(0);
      expect(readdirSync(hostState)).toEqual([]);
    } finally {
      delete process.env.XDG_STATE_HOME;
      rmSync(hostState, { recursive: true, force: true });
      rmSync(home, { recursive: true, force: true });
    }
  }, TIMEOUT);

  linuxTest("a fresh Linux home writes under the XDG roots only", async () => {
    const home = makeHome();
    try {
      const doctor = await runFx(["doctor"], { env: { HOME: home }, timeoutMs: TIMEOUT });

      expect(doctor.code).toBe(0);
      expect(profileLine(doctor.stdout)).toBe(
        `xdg layout; config=${join(home, ".config", "fx")} ` +
          `state=${join(home, ".local", "state", "fx")} ` +
          `data=${join(home, ".local", "share", "fx")}`,
      );

      const write = await runFx(["workspace", "add", home], {
        env: { HOME: home },
        timeoutMs: TIMEOUT,
      });

      expect(write.code).toBe(0);
      expect(existsSync(join(home, ".config", "fx", "settings.json"))).toBe(true);
      expect(existsSync(join(home, ".fx"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  }, TIMEOUT);

  linuxTest("an existing ~/.fx keeps every root on the legacy path", async () => {
    const home = makeHome();
    try {
      mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
      writeFileSync(join(home, ".fx", "settings.json"), "{}\n", { mode: 0o600 });

      const legacy = join(home, ".fx");
      const doctor = await runFx(["doctor"], { env: { HOME: home }, timeoutMs: TIMEOUT });

      expect(doctor.code).toBe(0);
      expect(profileLine(doctor.stdout)).toBe(
        `legacy layout; config=${legacy} state=${legacy} data=${legacy}`,
      );

      const write = await runFx(["workspace", "add", home], {
        env: { HOME: home },
        timeoutMs: TIMEOUT,
      });

      expect(write.code).toBe(0);
      expect(existsSync(join(home, ".config"))).toBe(false);
      expect(existsSync(join(home, ".local"))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  }, TIMEOUT);

  macosTest("macOS pins every root to ~/.fx whatever XDG exports", async () => {
    const home = makeHome();
    const xdgConfig = join(home, "explicit-xdg-config");
    try {
      mkdirSync(xdgConfig, { recursive: true, mode: 0o700 });

      const legacy = join(home, ".fx");
      const doctor = await runFx(["doctor"], {
        env: { HOME: home, XDG_CONFIG_HOME: xdgConfig },
        timeoutMs: TIMEOUT,
      });

      expect(doctor.code).toBe(0);
      expect(profileLine(doctor.stdout)).toBe(
        `legacy layout; config=${legacy} state=${legacy} data=${legacy}`,
      );

      const write = await runFx(["workspace", "add", home], {
        env: { HOME: home, XDG_CONFIG_HOME: xdgConfig },
        timeoutMs: TIMEOUT,
      });

      expect(write.code).toBe(0);
      // Every write landed in the legacy root, and the exported config root stayed empty.
      expect(existsSync(join(legacy, "settings.json"))).toBe(true);
      expect(readdirSync(xdgConfig)).toEqual([]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
