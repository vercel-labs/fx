/**
 * Suite-wide XDG isolation.
 *
 * fx resolves its profile roots from XDG_CONFIG_HOME, XDG_STATE_HOME, and XDG_DATA_HOME, and most
 * fixtures spawn the binary with a temporary HOME and a spread of `process.env`, so a developer
 * machine that exports any of these would send fx writes outside the fixture and produce results
 * that differ from CI.
 *
 * Clearing them here covers every spawn route at once, including the fixtures that do not go
 * through `TmuxSession` or `runFx`. Helpers still set the three profile variables explicitly
 * from the fixture HOME.
 */
import { XDG_ENV_KEYS } from "../test-support/profile-env";

process.env.FX_E2E_DISABLE_DOTENV = "1";
for (const key of XDG_ENV_KEYS) delete process.env[key];
