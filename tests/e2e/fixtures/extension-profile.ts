// A shared private profile keeps discovery and executable proofs isolated from developer credentials.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createIsolatedTestHome } from "../../evals/eval-helpers";

export const PROVIDER = "fixture-provider";
export const MODEL = `${PROVIDER}/fixture-model`;
export const EXTENSION_FIXTURE_KEY = "selected-extension-fixture-key";
export const PROFILE_DIRECTORY = ".fx";
export const SETTINGS_FILENAME = "settings.json";
export const FIXTURE_EXTENSION_DIRECTORY = "fixture-extension";
export const MODELS_FILENAME = "models.json";
const MANIFEST_FILENAME = "extension.json";
const PROFILE_SETTINGS = { provider: "extension", models: { extension: MODEL }, auto_upgrade: false };
const MODEL_FILE = { models: [{
  id: "fixture-model", wire_id: "fixture-wire", name: "Fixture model",
  tool_call: true, reasoning: true, reasoning_efforts: ["low", "max"],
  context_window: 8192, max_output_tokens: 1024,
}] };
export const VALID_MANIFEST = {
  version: 1, id: "fixture-extension", entrypoint: "fixture-binary",
  capabilities: ["providers"], providers: [{
    id: PROVIDER, base_url: "https://example.invalid/v1",
    api_key_env: "FX_EXTENSION_TEST_KEY", models_file: MODELS_FILENAME,
  }],
};
export const VALID_REGISTRY = { version: 1, extensions: [{ path: FIXTURE_EXTENSION_DIRECTORY }] };

// Caller owns cleanup so test failures cannot leak profiles between deterministic owners.
export function createExtensionProfile(registry: unknown, manifest: unknown): string {
  const home = createIsolatedTestHome();
  const profile = join(home, PROFILE_DIRECTORY);
  const extension = join(profile, FIXTURE_EXTENSION_DIRECTORY);
  mkdirSync(extension, { recursive: true });
  writeFileSync(join(profile, SETTINGS_FILENAME), JSON.stringify(PROFILE_SETTINGS));
  writeFileSync(join(profile, MANIFEST_FILENAME), JSON.stringify(registry));
  writeFileSync(join(extension, MANIFEST_FILENAME), JSON.stringify(manifest));
  writeFileSync(join(extension, MODELS_FILENAME), JSON.stringify(MODEL_FILE));
  return home;
}
