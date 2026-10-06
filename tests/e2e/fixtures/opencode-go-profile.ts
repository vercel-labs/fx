// The native provider always runs inside a disposable profile against a loopback peer.
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { FX_BIN } from "../../evals/eval-helpers";
import { createExtensionProfile, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY } from "./extension-profile";

const SOURCE = join(import.meta.dir, "..", "..", "..", "extensions", "fx-opencode-go");
const EXECUTABLE = join(dirname(FX_BIN), "fx-opencode-go");
const MANIFEST_FILENAME = "extension.json";
const CATALOG_FILENAME = "models.json";
const SETTINGS_FILENAME = "settings.json";
const MODEL = "opencode-go/deepseek-flash";
const SESSION_HEADER = "x-opencode-session";
const PROVIDER_ENTRYPOINT = "provider";
export const KEY = "local-go-fixture-key";
export const HEADER_VALUE = "local-go-fixture-header";
export const HOST = "127.0.0.1";

// Copies avoid escaping the extension root through executable symlinks.
export function createGoProfile(port: number, sessionHeader = SESSION_HEADER): string {
  const manifest = JSON.parse(readFileSync(join(SOURCE, MANIFEST_FILENAME), "utf8"));
  manifest.entrypoint = PROVIDER_ENTRYPOINT;
  manifest.providers[0].base_url = `http://${HOST}:${port}/v1`;
  manifest.providers[0].headers = { [sessionHeader]: { source: "session_id" },
    "x-go-fixture": { source: "env", name: "FX_GO_TEST_HEADER" } };
  const home = createExtensionProfile({ version: 1, extensions: [{ path: FIXTURE_EXTENSION_DIRECTORY }] }, manifest);
  const extension = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY);
  copyFileSync(EXECUTABLE, join(extension, manifest.entrypoint));
  copyFileSync(join(SOURCE, CATALOG_FILENAME), join(extension, CATALOG_FILENAME));
  writeFileSync(join(home, PROFILE_DIRECTORY, SETTINGS_FILENAME), JSON.stringify({ provider: "extension", models: { extension: MODEL }, effort: "max", auto_upgrade: false }));
  return home;
}

// No installed fx or ambient credential can replace the selected local proof.
export function goEnvironment(home: string): Record<string, string | undefined> {
  return { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
    FX_MODEL: undefined, FX_PERMISSION_MODE: "yolo", OPENCODE_API_KEY: KEY, FX_GO_TEST_HEADER: HEADER_VALUE,
    FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1" };
}
