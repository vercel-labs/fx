import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildEvalArgs,
  buildEvalProcessEnv,
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
  needsProcessSnapshot,
  runEval,
  runFx,
  shouldLoadDotEnv,
} from "./eval-helpers";

function evalHomes(): Set<string> {
  return new Set(
    readdirSync(tmpdir()).filter((name) => name.startsWith("fx-eval-home-")),
  );
}

describe("eval helpers", () => {
  test("passes the selected eval model to fx through FX_MODEL", () => {
    const previous = process.env.FX_MODEL;
    process.env.FX_MODEL = "ambient/model";

    try {
      const env = buildEvalProcessEnv("/tmp/fx-eval-home-test", "selected/model");

      expect(env.FX_MODEL).toBe("selected/model");
      expect(env.HOME).toBe("/tmp/fx-eval-home-test");
      expect(env.NO_COLOR).toBe("1");
    } finally {
      if (previous === undefined) {
        delete process.env.FX_MODEL;
      } else {
        process.env.FX_MODEL = previous;
      }
    }
  });

  test("passes the eval budget to fx --timeout in seconds", () => {
    const args = buildEvalArgs("hello", 150);
    const flag = args.indexOf("--timeout");

    expect(flag).toBeGreaterThan(-1);
    expect(args[flag + 1]).toBe("150");
    expect(args.at(-1)).toBe("hello");
  });

  test.skipIf(!existsSync(FX_BIN))(
    "stops fx when the eval budget runs out and removes its home",
    async () => {
      let modelRequests = 0;
      const gateway = Bun.serve({
        port: 0,
        idleTimeout: 0,
        fetch(req) {
          if (new URL(req.url).pathname === "/coding-agent/v1/models") {
            return Response.json({
              data: [{ id: "fake/model", type: "language", tags: ["tool-use"] }],
            });
          }
          if (req.method === "POST") modelRequests += 1;
          return new Promise<Response>(() => {});
        },
      });
      const overrides: Record<string, string> = {
        AI_GATEWAY_API_KEY: "fake-key",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: `http://127.0.0.1:${gateway.port}`,
        FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${gateway.port}/v4/ai/language-model`,
      };
      const previous = Object.fromEntries(
        Object.keys(overrides).map((key) => [key, process.env[key]]),
      );
      Object.assign(process.env, overrides);
      const homesBefore = evalHomes();
      // Bun's 15s test timeout did not end this test when runEval never
      // stopped fx, so the test keeps its own deadline.
      let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
      const deadline = new Promise<never>((_, reject) => {
        deadlineTimer = setTimeout(
          () => reject(new Error("runEval did not stop fx within 10s")),
          10_000,
        );
      });

      try {
        await expect(
          Promise.race([
            runEval("hello", { model: "fake/model", timeoutSec: 1 }),
            deadline,
          ]),
        ).rejects.toThrow("fx ask did not finish within 1s");
        expect(modelRequests).toBeGreaterThan(0);
        expect([...evalHomes()].filter((name) => !homesBefore.has(name))).toEqual([]);
      } finally {
        clearTimeout(deadlineTimer);
        for (const [key, value] of Object.entries(previous)) {
          if (value === undefined) {
            delete process.env[key];
          } else {
            process.env[key] = value;
          }
        }
        gateway.stop(true);
      }
    },
    15_000,
  );

  test("does not load repository dotenv files in a hermetic run", () => {
    expect(shouldLoadDotEnv({ FX_E2E_DISABLE_DOTENV: "1" })).toBe(false);
    expect(shouldLoadDotEnv({})).toBe(true);
  });

  test("runFx takes the process snapshot after a timeout or a signal", () => {
    expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: false })).toBe(false);
    expect(needsProcessSnapshot({ code: 2, signal: null, timedOut: false })).toBe(false);
    expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: true })).toBe(true);
    expect(needsProcessSnapshot({ code: null, signal: "SIGTERM", timedOut: false })).toBe(true);
  });

  test("runFx takes the process snapshot on a plain failure when asked", () => {
    expect(needsProcessSnapshot({ code: 2, signal: null, timedOut: false }, true)).toBe(true);
    expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: false }, true)).toBe(false);
  });

  test.skipIf(!existsSync(FX_BIN))(
    "runFx passes FX_HOME to fx only when the test sets it",
    async () => {
      const previous = process.env.FX_HOME;
      const home = createIsolatedTestHome();
      const fxHome = createIsolatedTestHome();
      writeFileSync(join(fxHome, "settings.json"), '{"update_channel":"dev"}\n');
      process.env.FX_HOME = fxHome;
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SOUND: "0",
      };

      try {
        const inherited = await runFx(["status", "--json"], { env });
        expect(inherited.code).toBe(0);
        expect(JSON.parse(inherited.stdout).update_channel).toBe("stable");

        const passed = await runFx(["status", "--json"], { env: { ...env, FX_HOME: fxHome } });
        expect(passed.code).toBe(0);
        expect(JSON.parse(passed.stdout).update_channel).toBe("dev");
      } finally {
        if (previous === undefined) {
          delete process.env.FX_HOME;
        } else {
          process.env.FX_HOME = previous;
        }
        cleanupIsolatedTestHome(fxHome);
        cleanupIsolatedTestHome(home);
      }
    },
  );
});
