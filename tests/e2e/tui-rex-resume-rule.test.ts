import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { waitForRootTurnCommitted } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
} from "./tmux-helpers";

const TOKEN = "e2e-rex-resume-rule-token-0123";
const TIMEOUT = 30_000;
const TEST_TIMEOUT = 90_000;
const THREE_RUNS_TEST_TIMEOUT = 150_000;

const REQUIRE_LINE = 'require("fx") -- fx resume rule; turn it off with the rex_resume_rule setting';
const REQUIRE_TEXT = `${REQUIRE_LINE}\n`;
const FX_LUA_FIRST_LINE = "-- Written by fx. fx owns this file and its Rex resume rule.";
const NOTICE = "fx added its Rex resume rule";
const TRACE_OUTCOME = "[rex_rule] outcome=";
const ADDED_TRACE = "[rex_rule] outcome=added reason=rule added";
const EXISTING_INIT = 'rex.set("resume.trust.claude.dir", "~/code")\nrex.bind("cmd+d", "pane.split", { direction = "right" })\n';
const BROKEN_INIT = 'rex.bind("cmd+d", "BROKEN")\n';

const FIRST_PROMPT = "rex resume rule first prompt";
const SECOND_PROMPT = "rex resume rule second prompt";
const FIRST_ANSWER = "REX_RULE_FIRST_ANSWER";
const SECOND_ANSWER = "REX_RULE_SECOND_ANSWER";
const UNEXPECTED_ANSWER = "REX_RULE_UNEXPECTED_ANSWER";

type Gateway = ReturnType<typeof startDynamicFakeGateway>;

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
  config: string;
  configRex: string;
  rexBin: string;
};

type RunFiles = {
  trace: string;
  tape: string;
  stderr: string;
};

function shellQuote(text: string): string {
  return `'${text.replaceAll("'", "'\\''")}'`;
}

function fakeRexScript(dir: string): string {
  const calls = shellQuote(join(dir, "calls.log"));
  const reloaded = shellQuote(join(dir, "reloaded"));
  return [
    "#!/bin/sh",
    `echo "$*" >> ${calls}`,
    'case "$1" in',
    "  block)",
    `    if [ -e ${reloaded} ] && grep -qF 'require("fx")' "$XDG_CONFIG_HOME/rex/init.lua" 2>/dev/null && [ -e "$XDG_CONFIG_HOME/rex/fx.lua" ]; then tail='"trusted":true,"rule":"fx"'; else tail='"untrusted_reason":"no_rule"'; fi`,
    `    printf '{"records":[{"owner":{"pid":%s,"name":"fx"},"program":"fx","reported_at":"2026-11-27T12:00:00Z","command":["fx"],%s}]}' "$PPID" "$tail"`,
    "    exit 0",
    "    ;;",
    "  config)",
    '    case "$2" in',
    '      check) if grep -q BROKEN "$3"; then exit 1; fi; exit 0 ;;',
    `      reload) : > ${reloaded}; exit 0 ;;`,
    "    esac",
    "    ;;",
    "esac",
    "exit 1",
    "",
  ].join("\n");
}

function installFakeRex(dir: string): void {
  mkdirSync(dir, { recursive: true });
  const rex = join(dir, "rex");
  writeFileSync(rex, fakeRexScript(dir));
  chmodSync(rex, 0o755);
}

function createFixtureRoot(label: string): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-rex-rule-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const config = join(root, "config");
  const rexBin = join(root, "rexbin");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(config, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  installFakeRex(rexBin);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    config,
    configRex: join(config, "rex"),
    rexBin,
  };
}

function runFiles(fixture: FixtureRoot, label: string): RunFiles {
  return {
    trace: join(fixture.root, `${label}-trace.log`),
    tape: join(fixture.root, `${label}-session.fxtape`),
    stderr: join(fixture.root, `${label}-stderr.log`),
  };
}

function answerGateway(answers: ReadonlyArray<readonly [prompt: string, answer: string]>): Gateway {
  return startDynamicFakeGateway((body) => {
    const match = answers.find(([prompt]) => body.includes(prompt));
    return fakeGatewayFinalText(match?.[1] ?? UNEXPECTED_ANSWER);
  });
}

function launchFx(fixture: FixtureRoot, gateway: Gateway, files: RunFiles, rexBin: string): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: JSON.stringify(FX_BIN),
    cwd: fixture.workspace,
    isolated: true,
    stderrPath: files.stderr,
    env: {
      HOME: fixture.home,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      AI_GATEWAY_API_KEY: "synthetic-rex-resume-rule",
      FX_AUTO_UPGRADE: "0",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_SOUND: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_RECORD: files.tape,
      FX_TRACE_LOG: files.trace,
      FX_TRACE_SCOPES: "agent,core,gateway,stream,rex_rule",
      OSC7577_TOKEN: TOKEN,
      REX_BIN_DIR: rexBin,
      REX_BLOCK: "block-1",
      REX_SERVER: "unix:///tmp/fx-e2e-rex.sock",
      XDG_CONFIG_HOME: fixture.config,
    },
  });
}

function filesUnder(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return filesUnder(path);
    return entry.isFile() ? [path] : [];
  });
}

function countOf(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

async function waitForTrace(path: string, needle: string): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let text = "";
  while (Date.now() < deadline) {
    text = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (text.includes(needle)) return text;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for "${needle}" in ${path}\n${text}`);
}

async function sendPrompt(session: TmuxSession, home: string, prompt: string, answer: string, committedBefore: number): Promise<void> {
  await session.waitForStableComposer(15_000);
  await session.sendText(prompt);
  await session.waitForText(answer, TIMEOUT);
  await session.waitForPane(turnSettled, TIMEOUT);
  await waitForRootTurnCommitted(home, committedBefore, TIMEOUT);
}

async function quit(session: TmuxSession): Promise<void> {
  await session.sendText("/quit");
  expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
}

function initPath(fixture: FixtureRoot): string {
  return join(fixture.configRex, "init.lua");
}

function fxLuaPath(fixture: FixtureRoot): string {
  return join(fixture.configRex, "fx.lua");
}

function statePath(fixture: FixtureRoot): string {
  return join(fixture.home, ".fx", "rex", "state.json");
}

function callsLog(dir: string): string {
  const path = join(dir, "calls.log");
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function addedFolders(fixture: FixtureRoot): string[] {
  return JSON.parse(readFileSync(statePath(fixture), "utf8")).added;
}

async function addRuleOnFirstRun(fixture: FixtureRoot, gateway: Gateway, files: RunFiles): Promise<void> {
  const session = await launchFx(fixture, gateway, files, fixture.rexBin);
  try {
    await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
    await waitForTrace(files.trace, ADDED_TRACE);
    await session.waitForText(NOTICE, TIMEOUT);
    await quit(session);
  } finally {
    await session.kill();
  }
}

test.skipIf(!tmuxAvailable())(
  "adds the Rex resume rule on a fresh install and shows one notice",
  async () => {
    const fixture = createFixtureRoot("fresh");
    const files = runFiles(fixture, "run");
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, files, fixture.rexBin);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      await waitForTrace(files.trace, ADDED_TRACE);
      await session.waitForText(NOTICE, TIMEOUT);
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(1);
      await quit(session);

      expect(readFileSync(files.stderr, "utf8")).toBe("");
      expect(readFileSync(initPath(fixture), "utf8")).toBe(REQUIRE_TEXT);
      const fxLua = readFileSync(fxLuaPath(fixture), "utf8");
      expect(fxLua.split("\n")[0]).toBe(FX_LUA_FIRST_LINE);
      expect(fxLua).toContain("resume.trust.fx");
      expect(fxLua).toContain("rex.match.under(");
      expect(addedFolders(fixture)).toEqual([fixture.configRex]);
      const calls = callsLog(fixture.rexBin);
      expect(calls).toContain("config check ");
      expect(calls).toContain("config reload");
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "keeps the lines of an existing init.lua and adds the require line after them",
  async () => {
    const fixture = createFixtureRoot("existing");
    const files = runFiles(fixture, "run");
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      mkdirSync(fixture.configRex, { recursive: true });
      writeFileSync(initPath(fixture), EXISTING_INIT);

      session = await launchFx(fixture, gateway, files, fixture.rexBin);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      await waitForTrace(files.trace, ADDED_TRACE);
      await session.waitForText(NOTICE, TIMEOUT);
      await quit(session);

      expect(readFileSync(initPath(fixture), "utf8")).toBe(EXISTING_INIT + REQUIRE_TEXT);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "leaves a broken init.lua alone and does not reload Rex",
  async () => {
    const fixture = createFixtureRoot("broken");
    const files = runFiles(fixture, "run");
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      mkdirSync(fixture.configRex, { recursive: true });
      writeFileSync(initPath(fixture), BROKEN_INIT);

      session = await launchFx(fixture, gateway, files, fixture.rexBin);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      await waitForTrace(files.trace, "[rex_rule] outcome=skipped reason=config_broken");
      await waitForTrace(files.trace, `${TRACE_OUTCOME}skipped\n`);
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(0);
      await quit(session);

      expect(readFileSync(initPath(fixture), "utf8")).toBe(BROKEN_INIT);
      expect(existsSync(fxLuaPath(fixture))).toBe(false);
      const calls = callsLog(fixture.rexBin);
      expect(calls).toContain("config check ");
      expect(calls).not.toContain("config reload");
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "leaves a read-only init.lua alone",
  async () => {
    const fixture = createFixtureRoot("read-only");
    const files = runFiles(fixture, "run");
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      mkdirSync(fixture.configRex, { recursive: true });
      writeFileSync(initPath(fixture), EXISTING_INIT);
      chmodSync(initPath(fixture), 0o444);

      session = await launchFx(fixture, gateway, files, fixture.rexBin);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      await waitForTrace(files.trace, "[rex_rule] outcome=skipped reason=init_read_only");
      await waitForTrace(files.trace, `${TRACE_OUTCOME}skipped\n`);
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(0);
      await quit(session);

      expect(readFileSync(initPath(fixture), "utf8")).toBe(EXISTING_INIT);
      expect(existsSync(fxLuaPath(fixture))).toBe(false);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "removes the rule when the rex_resume_rule setting is turned off",
  async () => {
    const fixture = createFixtureRoot("setting-off");
    const first = runFiles(fixture, "first");
    const second = runFiles(fixture, "second");
    const gateway = answerGateway([
      [FIRST_PROMPT, FIRST_ANSWER],
      [SECOND_PROMPT, SECOND_ANSWER],
    ]);
    let session: TmuxSession | undefined;
    try {
      await addRuleOnFirstRun(fixture, gateway, first);
      expect(readFileSync(initPath(fixture), "utf8")).toBe(REQUIRE_TEXT);
      expect(existsSync(fxLuaPath(fixture))).toBe(true);

      writeFileSync(join(fixture.home, ".fx", "settings.json"), JSON.stringify({ rex_resume_rule: false }));
      session = await launchFx(fixture, gateway, second, fixture.rexBin);
      await sendPrompt(session, fixture.home, SECOND_PROMPT, SECOND_ANSWER, 1);
      await waitForTrace(second.trace, `${TRACE_OUTCOME}removed reason=rule removed`);
      await waitForTrace(second.trace, `${TRACE_OUTCOME}removed\n`);
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(0);
      await quit(session);

      expect(existsSync(initPath(fixture))).toBe(false);
      expect(existsSync(fxLuaPath(fixture))).toBe(false);
      expect(addedFolders(fixture)).toEqual([]);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "does not add the require line back after the user removed it",
  async () => {
    const fixture = createFixtureRoot("user-removed");
    const first = runFiles(fixture, "first");
    const second = runFiles(fixture, "second");
    const gateway = answerGateway([
      [FIRST_PROMPT, FIRST_ANSWER],
      [SECOND_PROMPT, SECOND_ANSWER],
    ]);
    let session: TmuxSession | undefined;
    try {
      await addRuleOnFirstRun(fixture, gateway, first);
      const edited = readFileSync(initPath(fixture), "utf8").replace(REQUIRE_TEXT, "");
      expect(edited).not.toContain(REQUIRE_LINE);
      writeFileSync(initPath(fixture), edited);

      session = await launchFx(fixture, gateway, second, fixture.rexBin);
      await sendPrompt(session, fixture.home, SECOND_PROMPT, SECOND_ANSWER, 1);
      await waitForTrace(second.trace, "[rex_rule] outcome=skipped reason=user_removed");
      await waitForTrace(second.trace, `${TRACE_OUTCOME}skipped\n`);
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(0);
      await quit(session);

      expect(readFileSync(initPath(fixture), "utf8")).toBe(edited);
      expect(readFileSync(initPath(fixture), "utf8")).not.toContain(REQUIRE_LINE);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "does not run a rex inside the workspace",
  async () => {
    const fixture = createFixtureRoot("in-workspace");
    const files = runFiles(fixture, "run");
    const rexInWorkspace = join(fixture.workspace, "rexbin");
    installFakeRex(rexInWorkspace);
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, files, rexInWorkspace);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      const trace = await waitForTrace(files.trace, `${TRACE_OUTCOME}none\n`);
      expect(trace).toContain("[rex_rule] rex gate closed check=rex inside workspace root");
      expect(countOf(await session.captureFullScrollback(), NOTICE)).toBe(0);
      await quit(session);

      expect(existsSync(join(rexInWorkspace, "calls.log"))).toBe(false);
      expect(filesUnder(fixture.config)).toEqual([]);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "writes the require line once when three fx run at once",
  async () => {
    const fixture = createFixtureRoot("three");
    const runs = ["alpha", "beta", "gamma"].map((name) => ({
      prompt: `rex resume rule ${name} prompt`,
      answer: `REX_RULE_${name.toUpperCase()}_ANSWER`,
      files: runFiles(fixture, name),
    }));
    const gateway = answerGateway(runs.map((run) => [run.prompt, run.answer] as const));
    const sessions: TmuxSession[] = [];
    try {
      for (const run of runs) sessions.push(await launchFx(fixture, gateway, run.files, fixture.rexBin));
      for (const [index, session] of sessions.entries()) {
        await session.waitForStableComposer(15_000);
        await session.sendText(runs[index]!.prompt);
      }
      for (const [index, session] of sessions.entries()) {
        await session.waitForText(runs[index]!.answer, TIMEOUT);
        await session.waitForPane(turnSettled, TIMEOUT);
      }
      await waitForRootTurnCommitted(fixture.home, runs.length - 1, TIMEOUT);
      const traces = await Promise.all(runs.map((run) => waitForTrace(run.files.trace, TRACE_OUTCOME)));
      expect(traces.filter((trace) => trace.includes(ADDED_TRACE))).toHaveLength(1);

      for (const session of sessions) await quit(session);

      const lines = readFileSync(initPath(fixture), "utf8").split("\n");
      expect(lines.filter((line) => line === REQUIRE_LINE)).toHaveLength(1);
      expect(readFileSync(initPath(fixture), "utf8")).toBe(REQUIRE_TEXT);
    } finally {
      for (const session of sessions) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  THREE_RUNS_TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "keeps the token out of the files the rule writes",
  async () => {
    const fixture = createFixtureRoot("token");
    const files = runFiles(fixture, "run");
    const gateway = answerGateway([[FIRST_PROMPT, FIRST_ANSWER]]);
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, files, fixture.rexBin);
      await sendPrompt(session, fixture.home, FIRST_PROMPT, FIRST_ANSWER, 0);
      await waitForTrace(files.trace, ADDED_TRACE);
      await session.waitForText(NOTICE, TIMEOUT);
      await quit(session);

      expect(filesUnder(fixture.configRex).map((path) => basename(path)).sort()).toEqual(["fx.lua", "init.lua"]);
      expect(existsSync(statePath(fixture))).toBe(true);
      const searched = [
        ...filesUnder(fixture.configRex),
        ...filesUnder(join(fixture.home, ".fx", "rex")),
        files.trace,
        files.tape,
      ];
      const leaks = searched.filter((file) => readFileSync(file).includes(Buffer.from(TOKEN)));
      expect(leaks).toEqual([]);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);
