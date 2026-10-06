import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const PROVIDER = "fixture-provider";
const MODEL = `${PROVIDER}/fixture-model`;
const SECOND_PROVIDER = "fixture-second";
const SECOND_MODEL = `${SECOND_PROVIDER}/fixture-model`;
const PREFERRED_MODEL_ID = "fixture-preferred";
const PREFERRED_MODEL = `${PROVIDER}/${PREFERRED_MODEL_ID}`;
const NATIVE_SAVED_MODEL = "gateway/keep-model";
const EXTENSION_FIXTURE_KEY = "selected-extension-fixture-key";
const SECOND_EXTENSION_FIXTURE_KEY = "second-extension-fixture-key";
const PROVIDER_COMMAND = "provider";
const PROFILE_DIRECTORY = ".fx";
const SETTINGS_FILENAME = "settings.json";
const FIXTURE_EXTENSION_DIRECTORY = "fixture-extension";
const MODELS_FILENAME = "models.json";
const TIMEOUT_MS = 15_000;
const TUI_TIMEOUT_MS = 5_000;
const TUI_STDERR_FILENAME = "fx-stderr.log";
const SECOND_API_KEY_ENV = "FX_SECOND_EXTENSION_TEST_KEY";
const AUTH_SCOPE_PROMPT = "check scoped authentication";
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
  test("named provider selection preserves each preferred model and built-in preferences", () => {
    const home = fixture(VALID_REGISTRY, {
      ...VALID_MANIFEST, providers: [VALID_MANIFEST.providers[0], {
        ...VALID_MANIFEST.providers[0], id: SECOND_PROVIDER,
        api_key_env: SECOND_API_KEY_ENV,
      }],
    });
    const settingsPath = join(home, PROFILE_DIRECTORY, SETTINGS_FILENAME);
    const catalogPath = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, MODELS_FILENAME);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.models.gateway = NATIVE_SAVED_MODEL;
    settings.models[PROVIDER] = PREFERRED_MODEL;
    writeFileSync(settingsPath, JSON.stringify(settings));
    const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
    catalog.models.push({ ...catalog.models[0], id: PREFERRED_MODEL_ID });
    writeFileSync(catalogPath, JSON.stringify(catalog));

    // Fresh processes prove persisted namespace selection, not shared test memory.
    const selectProvider = (provider: string, secondKey: string | undefined) => spawnSync(FX_BIN, [PROVIDER_COMMAND, provider], {
      cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
      env: { ...process.env, HOME: home, FX_DISABLE_KEYCHAIN: "1",
        AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
        FX_SECOND_EXTENSION_TEST_KEY: secondKey,
        FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY },
    });
    const before = readFileSync(settingsPath, "utf8");
    const missing = selectProvider(SECOND_PROVIDER, undefined);
    expect(missing.status).toBe(1);
    expect(readFileSync(settingsPath, "utf8")).toBe(before);
    expect(missing.stderr).not.toContain(EXTENSION_FIXTURE_KEY);
    const second = selectProvider(SECOND_PROVIDER, SECOND_EXTENSION_FIXTURE_KEY);
    expect(second.stderr).toBe("");
    expect(second.status).toBe(0);
    const secondSettings = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(secondSettings.models.extension).toBe(SECOND_MODEL);
    expect(secondSettings.models[SECOND_PROVIDER]).toBe(SECOND_MODEL);
    const first = selectProvider(PROVIDER, SECOND_EXTENSION_FIXTURE_KEY);
    expect(first.stderr).toBe("");
    expect(first.status).toBe(0);
    const firstSettings = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(firstSettings.models.extension).toBe(PREFERRED_MODEL);
    expect(firstSettings.models[PROVIDER]).toBe(PREFERRED_MODEL);
    expect(firstSettings.models[SECOND_PROVIDER]).toBe(SECOND_MODEL);
    expect(firstSettings.models.gateway).toBe(NATIVE_SAVED_MODEL);
    expect(readFileSync(settingsPath, "utf8")).not.toContain(EXTENSION_FIXTURE_KEY);
    expect(readFileSync(settingsPath, "utf8")).not.toContain(SECOND_EXTENSION_FIXTURE_KEY);
  });
  test("valid typed headers remain offline and never read an environment-backed value", () => {
    const result = models(fixture(VALID_REGISTRY, { ...VALID_MANIFEST,
      providers: [{ ...VALID_MANIFEST.providers[0], headers: {
        "x-fixture-static": "fixture", "x-fixture-session": { source: "session_id" },
        "x-fixture-env": { source: "env", name: "FX_UNSET_HEADER_FIXTURE" },
      } }],
    }));
    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout).ids).toContain(MODEL);
  });

  test("rejects unsafe header bindings before credential or executable access", () => {
    const unsafe = [
      { "x-fixture": "unsafe-header-fixture\r\ninjected: true" },
      { Authorization: "unsafe-header-fixture" },
      { "x fixture": "unsafe-header-fixture" },
      { "x-fixture": { source: "env", name: "INVALID-ENV" } },
      { "x-fixture": { source: "session_id", extra: "unsafe-header-fixture" } },
    ];
    for (const headers of unsafe) {
      const result = models(fixture(VALID_REGISTRY, { ...VALID_MANIFEST,
        providers: [{ ...VALID_MANIFEST.providers[0], headers }],
      }));
      expect(result.status).not.toBe(0);
      expect(result.stderr + result.stdout).toContain("ExtensionHeaderInvalid");
      expect(result.stderr + result.stdout).not.toContain("unsafe-header-fixture");
    }
  });

  test("rejects unsafe endpoint and credential references during offline discovery", () => {
    const unsafe = [
      { base_url: "https://example.invalid/unsafe-endpoint-fixture\r\n" },
      { base_url: "https://user:unsafe-endpoint-fixture@example.invalid/v1" },
      { base_url: "http://example.invalid/v1" },
      { api_key_env: "INVALID-ENV" },
    ];
    for (const change of unsafe) {
      const result = models(fixture(VALID_REGISTRY, { ...VALID_MANIFEST,
        providers: [{ ...VALID_MANIFEST.providers[0], ...change }],
      }));
      expect(result.status).not.toBe(0);
      expect(result.stderr + result.stdout).toMatch(/ExtensionEndpointInvalid|ExtensionCredentialReferenceInvalid/);
      expect(result.stderr + result.stdout).not.toContain("unsafe-endpoint-fixture");
    }
  });

  test("rejects malformed reasoning and token limits before constructing menus", () => {
    const unsafe = [
      { reasoning_efforts: ["high\r\nunsafe-model-fixture"] },
      { reasoning_efforts: ["low", "low"] },
      { reasoning: false, reasoning_efforts: ["low"] },
      { context_window: 0 },
      { max_output_tokens: 0 },
      { context_window: 1024, max_output_tokens: 2048 },
    ];
    for (const change of unsafe) {
      const home = fixture(VALID_REGISTRY, VALID_MANIFEST);
      const path = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, MODELS_FILENAME);
      const catalog = JSON.parse(readFileSync(path, "utf8"));
      Object.assign(catalog.models[0], change);
      writeFileSync(path, JSON.stringify(catalog));
      const result = models(home);
      expect(result.status).not.toBe(0);
      expect(result.stderr + result.stdout).toContain("ExtensionModelInvalid");
      expect(result.stderr + result.stdout).not.toContain("unsafe-model-fixture");
    }
  });

  test("rejects duplicate provider declarations even when the first catalog is empty", () => {
    const home = fixture(VALID_REGISTRY, { ...VALID_MANIFEST,
      providers: [VALID_MANIFEST.providers[0], VALID_MANIFEST.providers[0]],
    });
    writeFileSync(join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, MODELS_FILENAME), JSON.stringify({ models: [] }));
    const result = models(home);
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionProviderDuplicate");
  });

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
    writeFileSync(join(home, PROFILE_DIRECTORY, SETTINGS_FILENAME), JSON.stringify({ provider: "gateway", auto_upgrade: false }));
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

  test("extension delivery stays fail-closed until executable activation is authorized", () => {
    const home = fixture(VALID_REGISTRY, VALID_MANIFEST);
    const result = spawnSync(FX_BIN, ["ask", "--json", "--no-save", AUTH_SCOPE_PROMPT], {
      cwd: home, timeout: TIMEOUT_MS, encoding: "utf8",
      env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
        FX_MODEL: undefined, FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY,
        FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1" },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionExecutionPermissionRequired");
    expect(result.stderr + result.stdout).not.toContain(EXTENSION_FIXTURE_KEY);
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

  tuiTest("switching extension models never reuses another provider's credential", async () => {
    const home = fixture(VALID_REGISTRY, { ...VALID_MANIFEST, providers: [
      VALID_MANIFEST.providers[0], { ...VALID_MANIFEST.providers[0], id: SECOND_PROVIDER,
        api_key_env: SECOND_API_KEY_ENV },
    ] });
    const catalogPath = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, MODELS_FILENAME);
    const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
    catalog.models[0].reasoning = false;
    catalog.models[0].reasoning_efforts = [];
    writeFileSync(catalogPath, JSON.stringify(catalog));
    const stderrPath = join(home, TUI_STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { HOME: home, AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "", FX_MODEL: undefined,
          FX_EXTENSION_TEST_KEY: EXTENSION_FIXTURE_KEY, FX_SECOND_EXTENSION_TEST_KEY: undefined,
          FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "0", FX_GATEWAY_BASE_URL: UNREACHABLE_GATEWAY },
      });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText("/model");
      await session.waitForText(SECOND_MODEL, TUI_TIMEOUT_MS);
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText(SECOND_MODEL, TUI_TIMEOUT_MS);
      await session.sendText(AUTH_SCOPE_PROMPT);
      const pane = await session.waitForText(SECOND_API_KEY_ENV, TUI_TIMEOUT_MS);
      expect(pane).not.toContain(EXTENSION_FIXTURE_KEY);
      expect(session.isAlive()).toBe(true);
      const settings = JSON.parse(readFileSync(join(home, PROFILE_DIRECTORY, SETTINGS_FILENAME), "utf8"));
      expect(settings.models.extension).toBe(SECOND_MODEL);
    } finally {
      await session?.kill();
      if (session) expect(readFileSync(stderrPath, "utf8")).toBe("");
    }
  }, TIMEOUT_MS);

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
