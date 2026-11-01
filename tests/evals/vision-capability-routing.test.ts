import { afterEach, describe, expect, test } from "bun:test";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  HAS_API_KEY,
  REPO_ROOT,
  runFx,
  type FxRunResult,
  type HeadlessResult,
} from "./eval-helpers";

const TIMEOUT = 180_000;
const KIMI_MODEL = "moonshotai/kimi-k3";
const GLM_MODEL = "zai/glm-5.2-fast";
const UNKNOWN_MODEL = "unknown/fx-vision-capability-probe-not-real";
const IMAGE_FIXTURE = join(REPO_ROOT, "tests/e2e/fixtures/favicon.png");

type Root = {
  root: string;
  home: string;
  workspace: string;
  tracePath: string;
};

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createRoot(name: string): Root {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `${name}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  roots.push(root);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tracePath: join(root, "trace.log"),
  };
}

function liveEnv(root: Root, model: string) {
  return {
    HOME: root.home,
    FX_MODEL: model,
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_TRACE_LOG: root.tracePath,
    FX_TRACE_SCOPES: "agent,gateway,catalog,tool",
  };
}

function parseResult(result: FxRunResult): HeadlessResult {
  expect(result.timedOut, result.processStateAtTimeout).toBe(false);
  expect(result.signal).toBeNull();
  return JSON.parse(result.stdout.trim()) as HeadlessResult;
}

function normalizedLetters(output: string): string {
  return output.toLowerCase().replace(/[^a-z]/g, "");
}

function successfulVisionCalls(json: HeadlessResult) {
  return json.tool_calls.filter(
    (call) => call.name === "vision" && call.status === "success",
  );
}

describe.skipIf(!HAS_API_KEY)("eval: live Vision capability routing", () => {
  test(
    "Kimi reads native image input while Vision remains unavailable",
    async () => {
      const root = createRoot("fx-live-native-vision");
      const imagePath = join(root.workspace, "glyph.png");
      copyFileSync(IMAGE_FIXTURE, imagePath);

      const result = await runFx(
        [
          "ask",
          "--yolo",
          "--json",
          "--no-save",
          "--no-color",
          "--image",
          imagePath,
          "Read the two white Latin letters shown on the black background. Reply with those two letters only.",
        ],
        {
          cwd: root.workspace,
          env: liveEnv(root, KIMI_MODEL),
          timeoutMs: TIMEOUT,
        },
      );

      const json = parseResult(result);
      expect(result.code, result.stderr).toBe(0);
      expect(json.exit_code).toBe(0);
      expect(json.model).toBe(KIMI_MODEL);
      expect(normalizedLetters(json.final_output || json.output)).toBe("fx");
      expect(json.tool_calls.filter((call) => call.name === "vision")).toEqual([]);

      const trace = readFileSync(root.tracePath, "utf8");
      expect(trace).toContain("model catalog lookup outcome=ready_hit model=moonshotai/kimi-k3");
      expect(trace).toMatch(
        /event=vision_policy .*image_support=native route=native mode=unavailable/,
      );
      expect(trace).not.toContain("name=vision result_kind=model_output");
    },
    TIMEOUT,
  );

  test(
    "GLM uses required Vision for attached image input",
    async () => {
      const root = createRoot("fx-live-required-vision");
      const imagePath = join(root.workspace, "glyph.png");
      copyFileSync(IMAGE_FIXTURE, imagePath);

      const result = await runFx(
        [
          "ask",
          "--yolo",
          "--json",
          "--no-save",
          "--no-color",
          "--image",
          imagePath,
          "Read the two white Latin letters shown on the black background. Reply with those two letters only.",
        ],
        {
          cwd: root.workspace,
          env: liveEnv(root, GLM_MODEL),
          timeoutMs: TIMEOUT,
        },
      );

      const json = parseResult(result);
      expect(result.code, result.stderr).toBe(0);
      expect(json.exit_code).toBe(0);
      expect(json.model).toBe(GLM_MODEL);
      expect(normalizedLetters(json.final_output || json.output)).toBe("fx");
      expect(successfulVisionCalls(json)).toHaveLength(1);

      const trace = readFileSync(root.tracePath, "utf8");
      expect(trace).toContain("model catalog lookup outcome=ready_hit model=zai/glm-5.2-fast");
      expect(trace).toMatch(
        /event=vision_policy .*image_support=non_native route=fallback mode=required/,
      );
      expect(trace).toMatch(
        /event=vision_policy .*image_support=non_native route=fallback mode=optional/,
      );
      expect(trace).toContain("name=vision result_kind=model_output");
    },
    TIMEOUT,
  );

  test(
    "GLM exposes optional Vision for a workspace image path",
    async () => {
      const root = createRoot("fx-live-optional-vision");
      const imagePath = join(root.workspace, "glyph.png");
      copyFileSync(IMAGE_FIXTURE, imagePath);

      const result = await runFx(
        [
          "ask",
          "--yolo",
          "--json",
          "--no-save",
          "--no-color",
          `Call Vision to inspect the image file at ${imagePath}. Read the two white Latin letters and reply with those letters only.`,
        ],
        {
          cwd: root.workspace,
          env: liveEnv(root, GLM_MODEL),
          timeoutMs: TIMEOUT,
        },
      );

      const json = parseResult(result);
      expect(result.code, result.stderr).toBe(0);
      expect(json.exit_code).toBe(0);
      expect(json.model).toBe(GLM_MODEL);
      expect(normalizedLetters(json.final_output || json.output)).toBe("fx");
      expect(successfulVisionCalls(json)).toHaveLength(1);

      const trace = readFileSync(root.tracePath, "utf8");
      expect(trace).toMatch(
        /event=vision_policy .*image_support=non_native route=fallback mode=optional/,
      );
      expect(trace).not.toContain("mode=required");
      expect(trace).toContain("name=vision result_kind=model_output");
    },
    TIMEOUT,
  );

  test(
    "unknown model capability rejects image input after a real catalog lookup",
    async () => {
      const root = createRoot("fx-live-unknown-vision");
      const imagePath = join(root.workspace, "glyph.png");
      copyFileSync(IMAGE_FIXTURE, imagePath);

      const result = await runFx(
        [
          "ask",
          "--yolo",
          "--json",
          "--no-save",
          "--no-color",
          "--image",
          imagePath,
          "Read the image.",
        ],
        {
          cwd: root.workspace,
          env: liveEnv(root, UNKNOWN_MODEL),
          timeoutMs: TIMEOUT,
        },
      );

      const json = parseResult(result);
      expect(result.code).toBe(1);
      expect(json.exit_code).toBe(1);
      expect(json.model).toBe(UNKNOWN_MODEL);
      expect(json.error).toContain("ModelImageCapabilityUnavailable");

      const trace = readFileSync(root.tracePath, "utf8");
      expect(trace).toContain(`model catalog lookup outcome=missing_entry model=${UNKNOWN_MODEL}`);
      expect(trace).toMatch(
        /event=vision_policy .*image_support=unknown route=unavailable mode=unavailable/,
      );
      expect(trace).not.toContain("event=provider_admitted");
    },
    TIMEOUT,
  );
});
