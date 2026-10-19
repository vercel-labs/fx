import { describe, expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import {
  buildEvalArgs,
  buildEvalProcessEnv,
  FX_BIN,
  runEval,
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
        hostname: "127.0.0.1",
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
});
