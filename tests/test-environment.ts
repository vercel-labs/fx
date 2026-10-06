// Test children must stay silent even when the developer's profile enables sound.
const SOUND_ENVIRONMENT_KEY = "FX_SOUND";
export const FX_TEST_SOUND_DISABLED = "0";

// Clean child environments need silence without inheriting unrelated developer credentials.
export function silentFxEnv(environment: Record<string, string | undefined>): Record<string, string | undefined> {
  return { ...environment, [SOUND_ENVIRONMENT_KEY]: FX_TEST_SOUND_DISABLED };
}

// notifications.test.ts removes this override only where sound is the behavior under test.
process.env[SOUND_ENVIRONMENT_KEY] = FX_TEST_SOUND_DISABLED;
