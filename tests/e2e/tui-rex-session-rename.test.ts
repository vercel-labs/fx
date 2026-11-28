import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { waitForRootTurnCommitted } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const TEST_TIMEOUT = 90_000;
const BLOCK = "block:01e2e-rex-rename";
const MADE_UP_LABEL = "morning-atoll";
const PROMPT = "fix the login redirect";
const ANSWER = "REX_RENAME_ANSWER";
const RENAMED = "[rex_rename] outcome=renamed reason=renamed";
const NAMING_ON = '{"scope":"user","harnesses":[{"id":"pi","detected":true,"session_naming":true}]}';
const NAMING_OFF = '{"scope":"user","harnesses":[{"id":"pi","detected":true,"session_naming":false}]}';

type Gateway = ReturnType<typeof startDynamicFakeGateway>;

type Fixture = {
  root: string;
  home: string;
  workspace: string;
  rexBin: string;
  trace: string;
  stderr: string;
};

type FixtureOptions = {
  settings?: Record<string, unknown>;
  /// The rex script, or null for a Rex folder with no rex in it.
  script?: string | null;
  status?: string;
  sessionLabel?: string;
};

/// A fake `rex` that keeps the session label in `label` and Rex's rename
/// option in `status.json`, and logs each call, one per line, in `calls.log`.
function fakeRexScript(): string {
  return [
    "#!/bin/sh",
    'd=$(dirname "$0")',
    'printf \'%s\\n\' "$*" >> "$d/calls.log"',
    'case "$1 $2" in',
    '"skill status") cat "$d/status.json" ;;',
    `"session inspect") [ "$4" = "--" ] && [ "$5" = "${BLOCK}" ] || exit 4; printf '{"label":"%s","windows":[{"label":"Window 1"}]}' "$(cat "$d/label")" ;;`,
    `"session rename") [ "$3" = "--" ] && [ "$4" = "${BLOCK}" ] || exit 4; printf '%s' "$5" > "$d/label" ;;`,
    "*) exit 3 ;;",
    "esac",
    "",
  ].join("\n");
}

/// A Rex from before `rex skill status`: every command it lacks fails.
const OLD_REX_SCRIPT = [
  "#!/bin/sh",
  'printf \'%s\\n\' "$*" >> "$(dirname "$0")/calls.log"',
  'echo "Error: unknown command \\"$1\\" for \\"rex\\"" >&2',
  "exit 1",
  "",
].join("\n");

function createFixture(options: FixtureOptions = {}): Fixture {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const rexBin = join(root, "rexbin");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(rexBin, { recursive: true });
  // A model-written title would replace the first prompt's title later.
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ session_titles: false, ...options.settings }));
  if (options.script !== null) {
    writeFileSync(join(rexBin, "rex"), options.script ?? fakeRexScript());
    chmodSync(join(rexBin, "rex"), 0o755);
  }
  writeFileSync(join(rexBin, "status.json"), options.status ?? NAMING_ON);
  writeFileSync(join(rexBin, "label"), options.sessionLabel ?? MADE_UP_LABEL);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    rexBin,
    trace: join(root, "trace.log"),
    stderr: join(root, "stderr.log"),
  };
}

function launchFx(fixture: Fixture, gateway: Gateway, args = ""): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: `${JSON.stringify(FX_BIN)}${args}`,
    cwd: fixture.workspace,
    isolated: true,
    stderrPath: fixture.stderr,
    env: {
      HOME: fixture.home,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      AI_GATEWAY_API_KEY: "synthetic-rex-session-rename",
      FX_AUTO_UPGRADE: "0",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_SOUND: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_TRACE_LOG: fixture.trace,
      FX_TRACE_SCOPES: "core,session,rex_rename",
      REX_BIN_DIR: fixture.rexBin,
      REX_BLOCK: BLOCK,
      REX_SERVER: "unix:///tmp/fx-e2e-rex-rename.sock",
    },
  });
}

function readText(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function sessionLabel(fixture: Fixture): string {
  return readText(join(fixture.rexBin, "label"));
}

function rexCalls(fixture: Fixture): string[] {
  return readText(join(fixture.rexBin, "calls.log"))
    .split("\n")
    .filter((line) => line.length > 0);
}

function renameCalls(fixture: Fixture): string[] {
  return rexCalls(fixture).filter((line) => line.startsWith("session rename"));
}

function countOf(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

/// Waits until the trace holds `needle` `count` times, and returns the trace.
async function waitForTrace(fixture: Fixture, needle: string, count = 1): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let text = "";
  while (Date.now() < deadline) {
    text = readText(fixture.trace);
    if (countOf(text, needle) >= count) return text;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${count} of "${needle}" in ${fixture.trace}\n${text}`);
}

/// Runs one chat with one prompt, then `steps`, then quits. Returns the
/// screen and scrollback from just before the quit.
async function runChat(fixture: Fixture, steps: (session: TmuxSession) => Promise<void>): Promise<string> {
  const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(ANSWER));
  const session = await launchFx(fixture, gateway);
  try {
    await session.waitForStableComposer(15_000);
    await session.sendText(PROMPT);
    await session.waitForText(ANSWER, TIMEOUT);
    await session.waitForPane(turnSettled, TIMEOUT);
    await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);
    await steps(session);
    const screen = await session.captureFullScrollback();
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
    return screen;
  } finally {
    await session.kill();
    gateway.stop();
  }
}

async function withFixture(options: FixtureOptions, body: (fixture: Fixture) => Promise<void>): Promise<void> {
  const fixture = createFixture(options);
  try {
    await body(fixture);
  } finally {
    cleanupIsolatedTestHome(fixture.root);
  }
}

test.skipIf(!tmuxAvailable())(
  "renames Rex's made-up session label from the chat title, and again on /rename",
  () =>
    withFixture({}, async (fixture) => {
      await runChat(fixture, async (session) => {
        await waitForTrace(fixture, RENAMED);
        expect(sessionLabel(fixture)).toBe(PROMPT);

        await session.sendText("/rename Release checklist");
        await waitForTrace(fixture, RENAMED, 2);
        expect(sessionLabel(fixture)).toBe("Release checklist");
      });
      expect(renameCalls(fixture)).toEqual([`session rename -- ${BLOCK} ${PROMPT}`, `session rename -- ${BLOCK} Release checklist`]);
      // Every session call names this pane's block, so no other session is touched.
      for (const line of rexCalls(fixture).filter((call) => call.startsWith("session "))) expect(line).toContain(BLOCK);
      expect(readText(fixture.stderr)).toBe("");
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "names the Rex session after a resumed chat's saved title",
  () =>
    withFixture({}, async (fixture) => {
      await runChat(fixture, () => waitForTrace(fixture, RENAMED).then(() => {}));
      // A new Rex session for the same chat, as after a Rex restart.
      writeFileSync(join(fixture.rexBin, "label"), "quiet-meadow");
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(ANSWER));
      const session = await launchFx(fixture, gateway, " -c");
      try {
        await waitForTrace(fixture, RENAMED, 2);
        expect(sessionLabel(fixture)).toBe(PROMPT);
        await session.waitForStableComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      } finally {
        await session.kill();
        gateway.stop();
      }
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "leaves a session that a person named",
  () =>
    withFixture({ sessionLabel: "my project" }, async (fixture) => {
      const skipped = "[rex_rename] outcome=skipped reason=named_by_someone_else";
      await runChat(fixture, async (session) => {
        await waitForTrace(fixture, skipped);
        await session.sendText("/rename Release checklist");
        await waitForTrace(fixture, skipped, 2);
      });
      expect(sessionLabel(fixture)).toBe("my project");
      expect(renameCalls(fixture)).toEqual([]);
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "does not rename when Rex's rename option is off",
  () =>
    withFixture({ status: NAMING_OFF }, async (fixture) => {
      await runChat(fixture, () => waitForTrace(fixture, "[rex_rename] outcome=skipped reason=option_off").then(() => {}));
      expect(sessionLabel(fixture)).toBe(MADE_UP_LABEL);
      expect(rexCalls(fixture)).toEqual(["skill status --json"]);
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "runs no rex when the rex_session_rename setting is off",
  () =>
    withFixture({ settings: { rex_session_rename: false } }, async (fixture) => {
      await runChat(fixture, () => waitForTrace(fixture, "[rex_rename] outcome=skipped reason=setting_off").then(() => {}));
      expect(sessionLabel(fixture)).toBe(MADE_UP_LABEL);
      expect(rexCalls(fixture)).toEqual([]);
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "an old rex without skill status shows no error and renames nothing",
  () =>
    withFixture({ script: OLD_REX_SCRIPT }, async (fixture) => {
      const screen = await runChat(fixture, () => waitForTrace(fixture, "[rex_rename] outcome=failed reason=rex_unavailable").then(() => {}));
      expect(sessionLabel(fixture)).toBe(MADE_UP_LABEL);
      expect(rexCalls(fixture)).toEqual(["skill status --json"]);
      expect(screen).not.toContain("unknown command");
      expect(readText(fixture.stderr)).toBe("");
    }),
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a missing rex shows no error",
  () =>
    withFixture({ script: null }, async (fixture) => {
      const screen = await runChat(fixture, async () => {
        await waitForTrace(fixture, "[rex_rename] rex gate closed check=rex missing");
        await waitForTrace(fixture, "[rex_rename] outcome=failed reason=rex_unavailable");
      });
      // The word rex on screen would be an error about it.
      expect(screen).not.toMatch(/\brex\b/i);
      expect(readText(fixture.stderr)).toBe("");
    }),
  TEST_TIMEOUT,
);
