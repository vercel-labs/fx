import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const PROVIDER = "fixture-provider";
const MODEL = `${PROVIDER}/fixture-model`;
const TIMEOUT_MS = 15_000;
const TUI_TIMEOUT_MS = 5_000;
const TUI_STDERR_FILENAME = "fx-stderr.log";
const tuiTest = tmuxAvailable() ? test.serial : test.skip;
const UNREACHABLE_GATEWAY = "http://127.0.0.1:1";
const GATEWAY_FIXTURE_KEY = "wrong-gateway-fixture-key";
const INVALID_EXTENSION_KEY_MARKER = "invalid-extension-fixture";
const INVALID_EXTENSION_KEY = `${INVALID_EXTENSION_KEY_MARKER}\r\nkey`;
const homes: string[] = [];

// A private profile prevents discovery coverage from reading developer credentials.
function fixture(registry: unknown, manifest: unknown): string {
  const home = createIsolatedTestHome();
  homes.push(home);
  const profile = join(home, ".fx");
  const extension = join(profile, "fixture-extension");
  mkdirSync(extension, { recursive: true });
  writeFileSync(join(profile, "settings.json"), JSON.stringify({
    provider: "extension", models: { extension: MODEL }, auto_upgrade: false,
  }));
  writeFileSync(join(profile, "extension.json"), JSON.stringify(registry));
  writeFileSync(join(extension, "extension.json"), JSON.stringify(manifest));
  writeFileSync(join(extension, "models.json"), JSON.stringify({ models: [{
    id: "fixture-model", wire_id: "fixture-wire", name: "Fixture model",
    tool_call: true, reasoning: true, reasoning_efforts: ["low", "max"],
    context_window: 8192, max_output_tokens: 1024,
  }] }));
  return home;
}

const VALID_MANIFEST = {
  version: 1, id: "fixture-extension", entrypoint: "fixture-binary",
  capabilities: ["providers"], providers: [{
    id: PROVIDER, base_url: "https://example.invalid/v1",
    api_key_env: "FX_EXTENSION_TEST_KEY", models_file: "models.json",
  }],
};
const VALID_REGISTRY = { version: 1, extensions: [{ path: "fixture-extension" }] };

// Catalog inspection must remain offline and cannot activate arbitrary executables.
function models(home: string) {
  return spawnSync(FX_BIN, ["models", "--json"], {
    cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
    env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined, FX_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY, FX_DISABLE_KEYCHAIN: "1" },
  });
}

afterEach(() => {
  for (const home of homes.splice(0)) cleanupIsolatedTestHome(home);
});

describe("local extension discovery", () => {
  test("lists registered model metadata without launching the missing executable", () => {
    const result = models(fixture(VALID_REGISTRY, VALID_MANIFEST));
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout).ids).toContain(MODEL);
    expect(result.stderr).not.toContain("Vercel AI Gateway");
  });

  test("rejects a registry protocol version instead of using Gateway", () => {
    const result = models(fixture({ ...VALID_REGISTRY, version: 99 }, VALID_MANIFEST));
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionVersionUnsupported");
    expect(result.stderr + result.stdout).not.toContain("needs access to Vercel");
  });

  test("an invalid optional registry does not block built-in credential checks", () => {
    const home = fixture({ ...VALID_REGISTRY, version: 99 }, VALID_MANIFEST);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "gateway", auto_upgrade: false }));
    const result = spawnSync(FX_BIN, ["ask", "--json", "--no-save", "hello"], {
      cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
      env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
        FX_MODEL: undefined, FX_SKIP_ONBOARDING: "1", FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY, FX_DISABLE_KEYCHAIN: "1" },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("needs access to Vercel AI Gateway");
  });

  test("missing extension keys never fall back to Gateway credentials", () => {
    const home = fixture(VALID_REGISTRY, VALID_MANIFEST);
    const result = spawnSync(FX_BIN, ["ask", "--json", "--no-save", "hello"], {
      cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
      env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: GATEWAY_FIXTURE_KEY,
        VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined, FX_EXTENSION_TEST_KEY: undefined,
        FX_SKIP_ONBOARDING: "1", FX_DISABLE_KEYCHAIN: "1", FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("selected extension provider");
    expect(result.stderr + result.stdout).not.toContain("Vercel AI Gateway");
    expect(result.stderr + result.stdout).not.toContain(GATEWAY_FIXTURE_KEY);
  });

  test("selected extension keys reject control bytes without exposing their value", () => {
    const home = fixture(VALID_REGISTRY, VALID_MANIFEST);
    const result = spawnSync(FX_BIN, ["ask", "--json", "--no-save", "hello"], {
      cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
      env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: GATEWAY_FIXTURE_KEY,
        VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined, FX_EXTENSION_TEST_KEY: INVALID_EXTENSION_KEY,
        FX_SKIP_ONBOARDING: "1", FX_DISABLE_KEYCHAIN: "1", FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionCredentialInvalid");
    expect(result.stderr + result.stdout).not.toContain(INVALID_EXTENSION_KEY_MARKER);
  });

  tuiTest("the model picker exposes cached extension reasoning without starting its executable", async () => {
    const home = fixture(VALID_REGISTRY, VALID_MANIFEST);
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_EXTENSION_TEST_KEY: undefined, FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0",
          FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText("/model");
      await session.waitForText(MODEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Enter");
      const pane = await session.waitForText(/\blow\b/i, TUI_TIMEOUT_MS);
      expect(pane).toMatch(/\bmax\b/i);
      await session.sendKeys("Escape");
      expect(session.isAlive()).toBe(true);
    } finally {
      await session?.kill();
      if (session) expect(readFileSync(stderrPath, "utf8")).toBe("");
    }
  }, TIMEOUT_MS);

  test("rejects reserved built-in provider identities", () => {
    const manifest = { ...VALID_MANIFEST, providers: [{ ...VALID_MANIFEST.providers[0], id: "gateway" }] };
    const result = models(fixture(VALID_REGISTRY, manifest));
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionProviderReserved");
  });
});
