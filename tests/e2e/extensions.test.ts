import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";

const PROVIDER = "fixture-provider";
const MODEL = `${PROVIDER}/fixture-model`;
const TIMEOUT_MS = 15_000;
const UNREACHABLE_GATEWAY = "http://127.0.0.1:1";
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

  test("rejects reserved built-in provider identities", () => {
    const manifest = { ...VALID_MANIFEST, providers: [{ ...VALID_MANIFEST.providers[0], id: "gateway" }] };
    const result = models(fixture(VALID_REGISTRY, manifest));
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toContain("ExtensionProviderReserved");
  });
});
