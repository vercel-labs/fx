/**
 * Suite-wide XDG isolation.
 *
 * fx resolves its profile roots from XDG_CONFIG_HOME, XDG_STATE_HOME, and XDG_DATA_HOME, and
 * places the terminal-host socket under XDG_RUNTIME_DIR. Most fixtures spawn the binary with a
 * temporary HOME and a spread of `process.env`, so a developer machine that exports any of
 * these would send fx writes outside the fixture and produce results that differ from CI.
 *
 * Clearing them here covers every spawn route at once, including the fixtures that do not go
 * through `TmuxSession` or `runFx`. Helpers still set the three profile variables explicitly
 * from the fixture HOME; a test that needs a runtime directory sets XDG_RUNTIME_DIR itself.
 */
import { XDG_ENV_KEYS } from "../evals/eval-helpers";

for (const key of XDG_ENV_KEYS) delete process.env[key];
