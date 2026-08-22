import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  classifierEvidenceFromRequest,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  fakeGatewayToolCall,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const TERMINAL_FIXTURE_SHELL = terminalFixtureShell();
const sessions: TmuxSession[] = [];
const roots: string[] = [];
const fixtureHomes: string[] = [];
const transportRoots = new Set<string>();
const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
const loginProfileName = (() => {
  const shell = userInfo().shell;
  if (shell.endsWith("/zsh")) return ".zprofile";
  if (shell.endsWith("/bash")) return ".bash_profile";
  return null;
})();

afterEach(async () => {
  for (const root of roots) writeFileSync(join(root, ".terminal-stop"), "");
  for (const session of sessions.splice(0)) await session.kill();
  await Promise.all(fixtureHomes.splice(0).map(cleanupTerminalHost));
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  for (const root of transportRoots) rmSync(root, { recursive: true, force: true });
  transportRoots.clear();
});

async function waitForTerminalHostExit(home: string): Promise<void> {
  const identityPath = join(home, ".fx", "terminal-host", "host.json");
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal host did not exit for ${home}`);
}

function terminalHostPid(home: string): number | null {
  const identityPath = join(home, ".fx", "terminal-host", "host.json");
  try {
    const identity = JSON.parse(readFileSync(identityPath, "utf8")) as { pid?: unknown };
    const pid = Number(identity.pid);
    return Number.isSafeInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

async function cleanupTerminalHost(home: string): Promise<void> {
  const identityPath = join(home, ".fx", "terminal-host", "host.json");
  const naturalDeadline = Date.now() + 3_000;
  while (Date.now() < naturalDeadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }

  const pid = terminalHostPid(home);
  if (pid === null || !processExists(pid)) return;
  try {
    process.kill(pid, "SIGTERM");
  } catch (error) {
    if (!processExists(pid)) return;
    throw error;
  }

  const termDeadline = Date.now() + 500;
  while (Date.now() < termDeadline) {
    if (!processExists(pid)) return;
    await Bun.sleep(25);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch (error) {
    if (!processExists(pid)) return;
    throw error;
  }
  const killDeadline = Date.now() + 500;
  while (Date.now() < killDeadline) {
    if (!processExists(pid)) return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal host cleanup could not stop pid ${pid} for ${home}`);
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function processGroupId(pid: number): number {
  const value = Number(
    execFileSync("ps", ["-p", String(pid), "-o", "pgid="], {
      encoding: "utf8",
    }).trim(),
  );
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`missing process group for ${pid}`);
  }
  return value;
}

async function waitForSignalMarker(path: string): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8") === "term") return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal signal marker did not appear at ${path}`);
}

function directChildPids(pid: number): number[] {
  return execFileSync("ps", ["-axo", "pid=,ppid="], { encoding: "utf8" })
    .trim()
    .split("\n")
    .map((line) => line.trim().split(/\s+/).map(Number))
    .filter(([, parent]) => parent === pid)
    .map(([child]) => child!);
}

function parentPid(pid: number): number {
  const value = Number(
    execFileSync("ps", ["-p", String(pid), "-o", "ppid="], {
      encoding: "utf8",
    }).trim(),
  );
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`missing parent process for ${pid}`);
  }
  return value;
}

async function waitForOwnedProcessExit(pids: number[]): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (pids.every((pid) => !processExists(pid))) return;
    await Bun.sleep(25);
  }
  throw new Error(`owned terminal processes did not exit: ${pids.join(",")}`);
}

async function cleanupNarrowReturn(
  fixture: ReturnType<typeof createFixture>,
  active: TmuxSession,
  childStarted: boolean,
): Promise<void> {
  const identityPath = join(fixture.home, ".fx", "terminal-host", "host.json");
  const identity = JSON.parse(
    await waitForTrace(identityPath, '"pid"'),
  ) as { pid: string };
  const hostPid = Number(identity.pid);
  expect(Number.isSafeInteger(hostPid) && hostPid > 0).toBe(true);

  const record = await waitForTerminalRecord(
    fixture.home,
    (candidate) => {
      const pid = Number(candidate.pid);
      return Number.isSafeInteger(pid) && pid > 0;
    },
  );
  const recordPid = Number(record.pid);
  const recordParentPid = parentPid(recordPid);
  const launcherPid = recordParentPid === hostPid ? recordPid : recordParentPid;
  const childPids = recordParentPid === hostPid
    ? directChildPids(launcherPid)
    : [recordPid];
  expect(childPids.length).toBeGreaterThan(0);

  if (childStarted && active.isAlive()) {
    const pane = await active.capturePane();
    const inManager = pane.includes("Background processes");
    const inTakeover = pane.includes("Ctrl-] d detach");
    if (!inTakeover) {
      if (!inManager) await active.sendKeys("C-x");
      await waitForBackgroundProcessManager(active);
      await active.sendKeys("Enter");
      await active.waitForPane(
        (current) =>
          current.includes("L1_PROMPT>") &&
          !current.includes("Background processes"),
        TIMEOUT,
      );
    }
    const promptCount = exactShellPromptCount(
      await active.captureFullScrollback(),
    );
    await active.sendKeys("C-c");
    await waitForNewExactShellPrompt(active, promptCount);
    await active.sendText("exit");
    await active.waitForText("Background processes", TIMEOUT);
  }

  await waitForOwnedProcessExit([launcherPid, ...childPids]);
  await active.kill();
  const activeIndex = sessions.indexOf(active);
  if (activeIndex >= 0) sessions.splice(activeIndex, 1);
  await waitForTerminalHostExit(fixture.home);
  await waitForOwnedProcessExit([hostPid]);

  const transport = terminalTransportPaths(fixture.home);
  expect(existsSync(identityPath)).toBe(false);
  expect(existsSync(transport.socket)).toBe(false);
  expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

  rmSync(fixture.root, { recursive: true, force: true });
  const rootIndex = roots.indexOf(fixture.root);
  if (rootIndex >= 0) roots.splice(rootIndex, 1);
  const homeIndex = fixtureHomes.indexOf(fixture.home);
  if (homeIndex >= 0) fixtureHomes.splice(homeIndex, 1);
  transportRoots.delete(transport.dir);
  expect(existsSync(fixture.root)).toBe(false);
}

function exactShellPromptCount(scrollback: string): number {
  return scrollback.split("\n").filter((line) => line.trimEnd() === "L1_PROMPT>")
    .length;
}

async function waitForNewExactShellPrompt(
  active: TmuxSession,
  previousCount: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const scrollback = await active.captureFullScrollback();
    if (exactShellPromptCount(scrollback) > previousCount) return;
    await Bun.sleep(25);
  }
  throw new Error("cleanup did not observe a new exact L1_PROMPT> after Ctrl-C");
}

async function waitForBackgroundProcessManager(
  active: TmuxSession,
): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let lastPane = "";
  while (Date.now() < deadline) {
    const pane = await active.capturePane();
    lastPane = pane;
    if (
      pane.includes("Background processes") &&
      !pane.includes("No background processes")
    ) {
      return pane;
    }
    if (
      pane.includes("Agents & processes") &&
      pane.includes("ctrl-x close") &&
      (pane.includes("No active agents") || pane.includes("No background processes"))
    ) {
      await active.sendKeys("C-x");
      await active.waitForPane((current) => !current.includes("ctrl-x close"), 2_000);
      await active.sendKeys("C-x");
      continue;
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for a background process in ${active.name}.\nLast pane:\n${lastPane}`,
  );
}

async function finishNarrowReturn(
  fixture: ReturnType<typeof createFixture>,
  active: TmuxSession,
  childStarted: boolean,
  primaryFailure?: unknown,
): Promise<void> {
  let cleanupFailure: unknown;
  try {
    await cleanupNarrowReturn(fixture, active, childStarted);
  } catch (error) {
    cleanupFailure = error;
  }

  if (primaryFailure !== undefined) {
    if (cleanupFailure !== undefined && primaryFailure instanceof Error) {
      Object.defineProperty(primaryFailure, "cause", {
        value: cleanupFailure,
        configurable: true,
      });
    }
    throw primaryFailure;
  }
  if (cleanupFailure !== undefined) throw cleanupFailure;
}

function holdUntilCleanup(root: string): string {
  return `while [ ! -e ${JSON.stringify(join(root, ".terminal-stop"))} ]; do sleep 0.05; done`;
}

function terminalTransportPaths(home: string) {
  const durableDir = join(home, ".fx", "terminal-host");
  const durableSocket = join(durableDir, "host.sock");
  const capacity = process.platform === "darwin" ? 104 : 108;
  if (Buffer.byteLength(durableSocket) < capacity) {
    return { dir: durableDir, socket: durableSocket };
  }
  const digest = createHash("sha256")
    .update("fx.terminal.transport.v1\0")
    .update(home)
    .digest("hex")
    .slice(0, 32);
  const base = process.platform === "darwin" ? "/private/tmp" : "/tmp";
  const dir = join(base, `fx-terminal-${process.getuid?.() ?? 0}-${digest}`);
  return { dir, socket: join(dir, "host.sock") };
}

function createFixture(prefix: string, endpointBytes?: number) {
  const root = realpathSync(mkdtempSync(join("/tmp", prefix)));
  const homeBase = join(root, "home");
  const home = endpointBytes === undefined
    ? homeBase
    : join(
      homeBase,
      "x".repeat(
        endpointBytes -
          Buffer.byteLength(homeBase) -
          Buffer.byteLength("/.fx/terminal-host/host.sock") -
          1,
      ),
    );
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "yolo",
      sandbox: "os",
      yolo_acknowledged: true,
      permission: {},
    }) + "\n",
  );
  writeFileSync(tracePath, "");
  writeFileSync(stderrPath, "");
  const imagePath = join(workspace, "fixture.png");
  writeFileSync(
    imagePath,
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  );
  roots.push(root);
  fixtureHomes.push(home);
  const transport = terminalTransportPaths(home);
  if (transport.dir !== join(home, ".fx", "terminal-host")) {
    transportRoots.add(transport.dir);
  }
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tracePath,
    stderrPath,
    imagePath,
  };
}

function writeTakeoverFixture(fixture: ReturnType<typeof createFixture>): string {
  const scriptPath = join(fixture.workspace, "takeover-fixture.sh");
  writeFileSync(
    scriptPath,
    `#!${TERMINAL_FIXTURE_SHELL}
stop_path=${JSON.stringify(join(fixture.root, ".terminal-stop"))}
(while [[ ! -e "$stop_path" ]]; do sleep 0.05; done; kill -TERM $$) &
guard_pid=$!
trap 'kill $guard_pid 2>/dev/null || true' EXIT
trap 'exit 130' INT
redraw() {
  local rows cols content_rows
  read rows cols <<< "$(stty size)"
  content_rows=$((rows > 1 ? rows - 1 : 1))
  printf '\\x1b[2J\\x1b[H'
  printf 'TAKEOVER_TOP\\nSIZE:%sx%s' "$cols" "$rows"
  printf '\\x1b[%s;1HTAKEOVER_BOTTOM' "$content_rows"
  printf '\\x1b[4;1H'
}
trap redraw WINCH
redraw
while IFS= read -r line; do
  redraw
  printf '\\x1b[4;1HECHO:%s\\x1b[K' "$line"
done
`,
  );
  chmodSync(scriptPath, 0o700);
  return scriptPath;
}

async function launch(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  extraEnv: Record<string, string | undefined> = {},
  cmd = FX_BIN,
  size = { width: 120, height: 30 },
) {
  const session = await TmuxSession.create({
    isolated: true,
    cmd,
    cwd: fixture.workspace,
    env: {
      HOME: fixture.home,
      SHELL: TERMINAL_FIXTURE_SHELL,
      AI_GATEWAY_API_KEY: "fake-terminal-tool-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: "yolo",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TRACE_LOG: fixture.tracePath,
      FX_TRACE_SCOPES:
        "input,terminal,terminal_client,terminal_store,terminal_host,agent,worker,gateway",
      FX_TERMINAL_HOST_IDLE_MS: "2500",
      ...extraEnv,
    },
    width: size.width,
    height: size.height,
    stderrPath: fixture.stderrPath,
  });
  sessions.push(session);
  await session.waitForComposer(TIMEOUT);
  return session;
}

function activeTaskId(home: string): string {
  const records = sessionRecords(home);
  const id = records.at(-1)?.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new Error(`missing active task id in ${home}`);
  }
  return id;
}

function terminalRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot).flatMap((sessionId) => {
    const terminalRoot = join(sessionsRoot, sessionId, "terminal", "state");
    if (!existsSync(terminalRoot)) return [];
    return readdirSync(terminalRoot).flatMap((name) => {
      const path = join(terminalRoot, name);
      return name.startsWith("record-") && name.endsWith(".json")
        ? [JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>]
        : [];
    });
  });
}

async function waitForTerminalRecord(
  home: string,
  predicate: (record: Record<string, unknown>) => boolean,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const record = terminalRecords(home).find(predicate);
    if (record) return record;
    await Bun.sleep(25);
  }
  throw new Error(`missing expected terminal record in ${home}`);
}

async function waitForTakeoverOwnerPid(home: string): Promise<number> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    for (const record of terminalRecords(home)) {
      const pid = Number(record.takeover_owner_pid);
      if (
        record.attention &&
        typeof record.attention === "object" &&
        (record.attention as Record<string, unknown>).write_lease === "human" &&
        Number.isSafeInteger(pid) &&
        pid > 0
      ) {
        return pid;
      }
    }
    await Bun.sleep(25);
  }
  throw new Error(`missing persisted takeover process owner in ${home}`);
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [
      contentText(value.text),
      contentText(value.value),
      contentText(value.content),
    ].join("");
  }
  return "";
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as {
    prompt: Array<{ content: unknown }>;
  };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) =>
    part.type === "tool-result" && part.toolCallId === callId
  );
  return result ? contentText(result.output) : `<missing ${callId}>`;
}

function toolCallInput(body: string, callId: string): Record<string, unknown> {
  const request = JSON.parse(body) as {
    prompt: Array<{ content: unknown }>;
  };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const call = parts.find((part) =>
    part.type === "tool-call" && part.toolCallId === callId
  );
  const input = call?.input;
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error(`missing tool call input for ${callId}`);
  }
  return input as Record<string, unknown>;
}

function fakeTerminalToolBatch(
  calls: Array<{ id: string; input: Record<string, unknown> }>,
) {
  return fakeGatewaySse([
    ...calls.map((call) => ({
      type: "tool-call",
      toolCallId: call.id,
      toolName: "terminal",
      input: call.input,
    })),
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

async function waitForTrace(path: string, needle: string): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const trace = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (trace.includes(needle)) return trace;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for trace ${needle}`);
}

function sessionRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot).flatMap((name) => {
    const path = join(sessionsRoot, name, "session.json");
    return existsSync(path)
      ? [JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>]
      : [];
  });
}

function sessionEventLogs(home: string): string {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return "";
  return readdirSync(sessionsRoot).map((name) => {
    const path = join(sessionsRoot, name, "events.jsonl");
    return existsSync(path) ? readFileSync(path, "utf8") : "";
  }).join("\n");
}

test.skipIf(!tmuxAvailable())(
  "manager terminal takeover forwards raw input resizes detaches and restores inline state",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-");
    const scriptPath = writeTakeoverFixture(fixture);
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TRACE_SCOPES:
        "input,terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
    });

    await active.sendText(`!${scriptPath}`);
    await active.waitForText("Running ", TIMEOUT);
    await waitForTerminalRecord(
      fixture.home,
      (record) => record.command === scriptPath && record.lifecycle === "running",
    );
    await active.sendLiteralText("TAKEOVER_INLINE_DRAFT");
    await active.sendKeys("C-x");
    await waitForBackgroundProcessManager(active);
    await active.sendKeys("Enter");
    let pane = await active.waitForPane(
      (current) =>
        current.includes("Ctrl-] d detach") &&
        current.includes("TAKEOVER_TOP") &&
        current.includes("TAKEOVER_BOTTOM"),
      TIMEOUT,
    );
    expect(pane).toContain("TAKEOVER_TOP");
    expect(pane).toContain("TAKEOVER_BOTTOM");
    expect(pane).not.toContain("Agents & processes");
    expect(pane).not.toContain("Background processes");
    expect(pane).not.toContain("ctrl-x close");

    await active.sendText("RAW_KEYBOARD");
    pane = await active.waitForPane(
      (current) =>
        current.includes("ECHO:RAW_KEYBOARD") &&
        current.includes("TAKEOVER_TOP") &&
        current.includes("TAKEOVER_BOTTOM"),
      TIMEOUT,
    );
    expect(pane).toContain("TAKEOVER_TOP");
    expect(pane).toContain("TAKEOVER_BOTTOM");
    await active.pasteText("RAW_PASTE\n");
    await active.waitForText("RAW_PASTE", TIMEOUT);
    await active.sendHexBytes(["1b", "5b", "49"]);
    await active.sendText("RAW_FOCUS");
    await active.waitForText("RAW_FOCUS", TIMEOUT);
    await active.sendHexBytes([
      "1b", "5b", "3c", "30", "3b", "31", "30", "3b", "35", "4d",
    ]);
    await active.sendText("RAW_MOUSE");
    await active.waitForText("RAW_MOUSE", TIMEOUT);

    await active.resizeWindow(72, 12);
    await active.sendText("RESIZE_CHECK");
    pane = await active.waitForText("SIZE:72x12", TIMEOUT);
    expect(pane).toContain("TAKEOVER_BOTTOM");
    await active.sendHexBytes(["1d", "3f"]);
    await active.waitForText("Ctrl-] d detach", TIMEOUT);
    await active.sendHexBytes(["1d", "64"]);
    pane = await active.waitForText("Background processes", TIMEOUT);
    expect(pane).toContain("Agents & processes");

    await active.sendKeys("C-x");
    await active.waitForText("TAKEOVER_INLINE_DRAFT", TIMEOUT);
    await active.resizeWindow(120, 30);
    await active.sendKeys("C-x");
    await waitForBackgroundProcessManager(active);
    await active.sendKeys("Enter");
    await active.waitForText("TAKEOVER_TOP", TIMEOUT);
    await active.sendKeys("C-c");
    await active.waitForText("Background processes", TIMEOUT);
    await active.sendKeys("C-x");
    await active.waitForText("TAKEOVER_INLINE_DRAFT", TIMEOUT);

    const trace = readFileSync(fixture.tracePath, "utf8");
    expect(trace).toContain("lease acquire submitted");
    expect(trace).toContain("write submitted");
    expect(trace).not.toContain("input dropped");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "takeover manager return rebuilds the recorded 60x12 inline viewport",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-narrow-return-");
    const tapePath = join(fixture.root, "session.fxtape");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(
      fixture,
      gateway,
      {
        FX_RECORD: tapePath,
        FX_RECORD_INPUT: "1",
        FX_TERMINAL_TEST_TAKEOVER_FAILURE: "release_admission",
        FX_TRACE_SCOPES:
          "input,render,resize,terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
      },
      FX_BIN,
      { width: 120, height: 36 },
    );
    const interactiveFlags = TERMINAL_FIXTURE_SHELL.endsWith("/zsh")
      ? "-f -i"
      : "--noprofile --norc -i";
    let childStarted = false;
    let primaryFailure: unknown;
    try {
      await active.sendText(
        `!printf 'L1_MARKER_1\\n'; sleep 1; printf 'L1_MARKER_2\\n'; export PS1='L1_PROMPT> '; exec ${JSON.stringify(TERMINAL_FIXTURE_SHELL)} ${interactiveFlags}`,
      );
      await active.waitForText("Running ", TIMEOUT);
      childStarted = true;
      await active.sendLiteralText("LANE1_COMPOSER_DRAFT_ABCDE");
      for (let index = 0; index < 5; index += 1) {
        await active.sendKeys("Left");
      }
      await active.sendKeys("C-x");
      await waitForBackgroundProcessManager(active);
      await active.sendKeys("Enter");
      await active.waitForText("L1_PROMPT>", TIMEOUT);

      await active.sendText("printf 'L1_SIZE_120='; stty size");
      await active.waitForText("L1_SIZE_120=36 120", TIMEOUT);
      await active.resizeWindow(88, 24);
      await active.sendText("printf 'L1_SIZE_88='; stty size");
      await active.waitForText("L1_SIZE_88=24 88", TIMEOUT);
      await active.resizeWindow(60, 12);
      await active.sendText("printf 'L1_SIZE_60='; stty size");
      await active.waitForText("L1_SIZE_60=12 60", TIMEOUT);

      await active.sendHexBytes(["1d", "64"]);
      await waitForTrace(
        fixture.tracePath,
        "action=release_admission error=InjectedTakeoverFailure",
      );
      await active.waitForText("Background processes", TIMEOUT);
      await active.sendKeys("C-x");
      await active.waitForText("LANE1_COMPOSER_DRAFT_ABCDE", TIMEOUT);
      const releaseTrace = await waitForTrace(
        fixture.tracePath,
        "lease release completed",
      );
      const retryIndex = releaseTrace.indexOf(
        "action=release_admission error=InjectedTakeoverFailure",
      );
      const recoveryIndex = releaseTrace.indexOf(
        "request_redraw mode=replay_viewport",
        retryIndex,
      );
      const releaseIndex = releaseTrace.indexOf(
        "lease release completed",
        retryIndex,
      );
      expect(retryIndex).toBeGreaterThanOrEqual(0);
      expect(recoveryIndex).toBeGreaterThan(retryIndex);
      expect(releaseIndex).toBeGreaterThan(recoveryIndex);
      expect(
        countOccurrences(
          releaseTrace.slice(retryIndex, releaseIndex),
          "request_redraw mode=replay_viewport",
        ),
      ).toBe(1);

      const grid = await active.capturePaneGrid();
      const viewport = grid.join("\n");
      const fullScrollback = await active.captureFullScrollback();
      expect(grid).toHaveLength(12);
      expect(grid).not.toContain("f");
      expect(grid.some((row) => /^[0-9a-f]{2}PS1=/.test(row))).toBe(false);
      expect(countOccurrences(viewport, "LANE1_COMPOSER_DRAFT_ABCDE")).toBe(1);
      expect(countOccurrences(fullScrollback, "● Terminal: Starting:")).toBe(1);
      expect(countOccurrences(fullScrollback, "● Terminal: Running")).toBe(1);
      expect(countOccurrences(fullScrollback, "LANE1_COMPOSER_DRAFT_ABCDE")).toBe(1);

      await active.sendLiteralText("Z");
      await active.waitForText("LANE1_COMPOSER_DRAFT_ZABCDE", TIMEOUT);
      await active.sendKeys("BSpace");
      await active.waitForText("LANE1_COMPOSER_DRAFT_ABCDE", TIMEOUT);
      await active.pasteText("P");
      await active.waitForText("LANE1_COMPOSER_DRAFT_PABCDE", TIMEOUT);
      await active.sendKeys("BSpace");
      await active.waitForText("LANE1_COMPOSER_DRAFT_ABCDE", TIMEOUT);
      await active.sendHexBytes(["1b", "5b", "49", "1b", "5b", "4f"]);
      let previousPane = "";
      let stablePaneMatches = 0;
      const settledPane = await active.waitForPane((pane) => {
        if (countOccurrences(pane, "LANE1_COMPOSER_DRAFT_ABCDE") !== 1) {
          previousPane = pane;
          stablePaneMatches = 0;
          return false;
        }
        stablePaneMatches = pane === previousPane ? stablePaneMatches + 1 : 1;
        previousPane = pane;
        return stablePaneMatches >= 2;
      }, TIMEOUT);
      const finalGrid = settledPane.replace(/\n$/, "").split("\n");
      const finalViewport = finalGrid.join("\n");
      const finalScrollback = await active.captureFullScrollback();
      expect(finalGrid).toHaveLength(12);
      expect(finalGrid).not.toContain("f");
      expect(finalGrid.some((row) => /^[0-9a-f]{2}PS1=/.test(row))).toBe(false);
      expect(countOccurrences(finalViewport, "LANE1_COMPOSER_DRAFT_ABCDE")).toBe(1);
      expect(countOccurrences(finalScrollback, "● Terminal: Starting:")).toBe(1);
      expect(countOccurrences(finalScrollback, "● Terminal: Running")).toBe(1);
      expect(countOccurrences(finalScrollback, "LANE1_COMPOSER_DRAFT_ABCDE")).toBe(1);

      const replay = Bun.spawnSync({
        cmd: [FX_BIN, "replay", tapePath],
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(replay.exitCode).toBe(0);
      expect(replay.stderr.toString()).toBe("");
      const replayGrid = replay.stdout.toString();
      expect(countOccurrences(replayGrid, "● Terminal: Starting:")).toBe(1);
      expect(countOccurrences(replayGrid, "● Terminal: Running")).toBe(1);
      expect(countOccurrences(replayGrid, "LANE1_COMPOSER_DRAFT_ABCDE")).toBe(1);
      const replayViewport = replayGrid
        .replace(/\n$/, "")
        .split("\n")
        .map((row) =>
          row.startsWith("|") && row.endsWith("|")
            ? row.slice(1, -1).trimEnd()
            : row.trimEnd()
        );
      expect(replayViewport).toHaveLength(12);
      expect(replayViewport).toEqual(finalGrid.map((row) => row.trimEnd()));
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } catch (error) {
      primaryFailure = error;
    }
    await finishNarrowReturn(fixture, active, childStarted, primaryFailure);
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "narrow takeover cleanup preserves a primary assertion failure",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-narrow-failure-");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    const interactiveFlags = TERMINAL_FIXTURE_SHELL.endsWith("/zsh")
      ? "-f -i"
      : "--noprofile --norc -i";
    let childStarted = false;
    let injectedFailure: unknown;
    let primaryFailure: unknown;

    try {
      await active.sendText(
        `!export PS1='L1_PROMPT> '; exec ${JSON.stringify(TERMINAL_FIXTURE_SHELL)} ${interactiveFlags}`,
      );
      await active.waitForText("Running ", TIMEOUT);
      childStarted = true;
      await active.sendKeys("C-x");
      await waitForBackgroundProcessManager(active);
      await active.sendKeys("Enter");
      await active.waitForText("L1_PROMPT>", TIMEOUT);
      try {
        expect("primary assertion").toBe("injected failure");
      } catch (error) {
        injectedFailure = error;
        throw error;
      }
    } catch (error) {
      primaryFailure = error;
    }

    let observedFailure: unknown;
    try {
      await finishNarrowReturn(fixture, active, childStarted, primaryFailure);
    } catch (error) {
      observedFailure = error;
    }
    expect(observedFailure).toBe(injectedFailure);
    expect(injectedFailure).toBeInstanceOf(Error);
    expect((injectedFailure as Error).cause).toBeUndefined();
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "takeover retains keyboard bytes submitted before delayed lease acquisition",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-delayed-");
    const scriptPath = writeTakeoverFixture(fixture);
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TERMINAL_TEST_TAKEOVER_ACQUIRE_DELAY_MS: "1500",
      FX_TRACE_SCOPES:
        "terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
    });

    await active.sendText(`!${scriptPath}`);
    await active.waitForText("Running ", TIMEOUT);
    await active.sendKeys("C-x");
    await waitForBackgroundProcessManager(active);
    await active.sendKeys("Enter");
    await waitForTrace(fixture.tracePath, "lease acquire submitted");
    await active.sendText("BEFORE_ACQUIRE");
    const pane = await active.waitForText("ECHO:BEFORE_ACQUIRE", TIMEOUT);
    expect(pane).toContain("TAKEOVER_TOP");
    expect(readFileSync(fixture.tracePath, "utf8")).not.toContain(
      "input dropped",
    );
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

for (const failure of [
  "acquire_admission",
  "worker_start",
  "paint",
  "resize",
  "write",
  "release_admission",
  "surface_return",
] as const) {
  test.skipIf(!tmuxAvailable())(
    `takeover ${failure} failure is contained and restores the exact inline draft`,
    async () => {
      const fixture = createFixture(`fx-tui-terminal-takeover-${failure}-`);
      const scriptPath = writeTakeoverFixture(fixture);
      const gateway = startFakeGateway([]);
      gateways.push(gateway);
      const active = await launch(fixture, gateway, {
        FX_TERMINAL_TEST_TAKEOVER_FAILURE: failure,
        FX_TRACE_SCOPES:
          "terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
      });

      await active.sendText(`!${scriptPath}`);
      await active.waitForText("Running ", TIMEOUT);
      await active.sendLiteralText(`INLINE_${failure}`);
      await active.sendKeys("C-x");
      await waitForBackgroundProcessManager(active);
      await active.sendKeys("Enter");
      if (failure === "write") {
        await active.waitForText("TAKEOVER_TOP", TIMEOUT);
        await active.sendLiteralText("FAIL_WRITE\r");
      } else if (
        failure === "release_admission" || failure === "surface_return"
      ) {
        await active.waitForText("TAKEOVER_TOP", TIMEOUT);
        await active.sendHexBytes(["1d", "64"]);
      }
      await waitForTrace(fixture.tracePath, "[terminal_takeover] failure id=");
      const manager = await active
        .waitForText("Background processes", TIMEOUT)
        .catch(async (error) => {
          throw new Error(
            `${error}\nPANE\n${await active.capturePane()}\nTRACE\n${readFileSync(fixture.tracePath, "utf8")}\nDURABLE\n${JSON.stringify(terminalRecords(fixture.home), null, 2)}`,
          );
        });
      expect(manager).toContain("Agents & processes");
      await active.sendKeys("C-x");
      await active.waitForText(`INLINE_${failure}`, TIMEOUT);

      const trace = readFileSync(fixture.tracePath, "utf8");
      expect(trace).toMatch(
        /\[terminal_takeover\].*failure id=.*phase=.*action=.*error=/,
      );
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    45_000,
  );
}

test.skipIf(!tmuxAvailable())(
  "tmux-backed agent session accepts only the authenticated human takeover lease",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-tmux-");
    const scriptPath = writeTakeoverFixture(fixture);
    const tmuxStart = (callId: string) =>
      fakeGatewayToolCall(callId, "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command: scriptPath,
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "tmux",
        return_when: { kind: "started" },
        dimensions: { rows: 24, columns: 80 },
      });
    const gatewayResponses = [
      tmuxStart("takeover_tmux_start"),
      fakeGatewayFinalText("AGENT_TMUX_READY"),
    ];
    const gateway = startFakeGateway(gatewayResponses);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TRACE_SCOPES:
        "terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
    });

    let startCallId = "takeover_tmux_start";
    await active.sendText("Start the tmux terminal fixture.");
    await active.waitForText("AGENT_TMUX_READY", TIMEOUT);
    let startResult = toolResultText(gateway.requests.at(-1)!.body, startCallId);
    if (startResult.includes('"code":"startup_failed"')) {
      console.error("Retrying tmux takeover fixture after startup failure");
      startCallId = "takeover_tmux_start_retry";
      gatewayResponses.push(
        tmuxStart(startCallId),
        fakeGatewayFinalText("AGENT_TMUX_RETRY_READY"),
      );
      await active.sendText("Retry the tmux terminal fixture.");
      await active.waitForText("AGENT_TMUX_RETRY_READY", TIMEOUT);
      startResult = toolResultText(gateway.requests.at(-1)!.body, startCallId);
    }
    if (!startResult.includes('"lifecycle":"running"')) {
      throw new Error(
        `${startResult}\n${readFileSync(fixture.tracePath, "utf8")}`,
      );
    }
    expect(startResult).toContain('"lifecycle":"running"');
    await active.sendLiteralText("AGENT_TMUX_INLINE_DRAFT");
    await active.sendKeys("C-x");
    const listed = await active.waitForText("Background processes", TIMEOUT);
    expect(listed).not.toContain("No background processes");
    await active.sendKeys("Enter");
    await active.waitForText("TAKEOVER_TOP", TIMEOUT);
    await active.sendText("AGENT_TMUX_INPUT");
    await active.waitForText("ECHO:AGENT_TMUX_INPUT", TIMEOUT);
    await active.sendHexBytes(["1d", "64"]);
    const manager = await active.waitForText("Background processes", TIMEOUT);
    expect(manager).toContain("Agents & processes");
    await active.sendKeys("C-x");
    await active.waitForText("AGENT_TMUX_INLINE_DRAFT", TIMEOUT);

    const trace = readFileSync(fixture.tracePath, "utf8");
    expect(trace).toContain("lease acquire submitted");
    expect(trace).toContain("write submitted");
    expect(trace).not.toContain("authority reload failed");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

for (const backend of ["native", "tmux"] as const) {
  test.skipIf(!tmuxAvailable())(
    `abrupt Fx death leaves a live ${backend} takeover discoverable and reclaimable on exact task resume`,
    async () => {
      const fixture = createFixture(`fx-tui-terminal-reclaim-${backend}-`);
      const scriptPath = writeTakeoverFixture(fixture);
      const gatewayResponses = [
        fakeGatewayToolCall(`reclaim_${backend}_start`, "terminal", {
          action: "start",
          cwd: fixture.workspace,
          command: scriptPath,
          shell: {
            kind: "executable",
            path: TERMINAL_FIXTURE_SHELL,
            clean_start: true,
          },
          backend,
          return_when: { kind: "started" },
          dimensions: { rows: 24, columns: 80 },
        }),
        fakeGatewayFinalText(`RECLAIM_${backend.toUpperCase()}_READY`),
      ];
      const gateway = startFakeGateway(gatewayResponses);
      gateways.push(gateway);
      const traceScopes =
        "terminal,terminal_takeover,terminal_client,terminal_store,terminal_host";
      const active = await launch(fixture, gateway, {
        FX_TRACE_SCOPES: traceScopes,
      });

      await active.sendText(`Start the reclaimable ${backend} terminal.`);
      await active.waitForText(
        `RECLAIM_${backend.toUpperCase()}_READY`,
        TIMEOUT,
      );
      const taskId = activeTaskId(fixture.home);
      await active.sendKeys("C-x");
      await waitForBackgroundProcessManager(active);
      await active.sendKeys("Enter");
      await active.waitForText("TAKEOVER_TOP", TIMEOUT);

      process.kill(await waitForTakeoverOwnerPid(fixture.home), "SIGKILL");
      const deathDeadline = Date.now() + 5_000;
      while (active.isAlive() && Date.now() < deathDeadline) {
        await Bun.sleep(25);
      }
      expect(active.isAlive()).toBe(false);

      const terminalId = terminalRecords(fixture.home).find(
        (record) => record.lifecycle === "running",
      )?.session_id;
      expect(typeof terminalId).toBe("string");
      const marker = `AGENT_RECLAIMED_${backend.toUpperCase()}`;
      gatewayResponses.push(
        fakeGatewayToolCall(`reclaim_${backend}_acquire`, "terminal", {
          action: "write",
          session_id: terminalId,
          lease: "acquire",
        }),
        fakeGatewayToolCall(`reclaim_${backend}_write`, "terminal", {
          action: "write",
          session_id: terminalId,
          lease: "use",
          write: { kind: "text", text: `${marker}\n` },
        }),
        fakeGatewayToolCall(`reclaim_${backend}_release`, "terminal", {
          action: "write",
          session_id: terminalId,
          lease: "release",
        }),
        fakeGatewayFinalText(`${marker}_READY`),
      );
      const resumed = await launch(
        fixture,
        gateway,
        { FX_TRACE_SCOPES: traceScopes },
        `${FX_BIN} resume --id ${taskId}`,
      );
      await resumed.sendText("Recover the terminal, write the marker, and release it.");
      await resumed.waitForText(`${marker}_READY`, TIMEOUT);
      const agentResultBody = gateway.requests.at(-1)!.body;
      expect(
        toolResultText(agentResultBody, `reclaim_${backend}_acquire`),
      ).toContain('"write_lease":"agent"');
      expect(
        toolResultText(agentResultBody, `reclaim_${backend}_write`),
      ).toContain('"accepted_bytes":');
      expect(
        toolResultText(agentResultBody, `reclaim_${backend}_release`),
      ).toContain('"write_lease":"none"');
      await resumed.sendKeys("C-x");
      await resumed.waitForPane(
        (pane) =>
          pane.includes("Background processes") &&
          !pane.includes("No background processes"),
        TIMEOUT,
      );
      const reconciled = terminalRecords(fixture.home).find(
        (record) => record.lifecycle === "running",
      );
      expect(reconciled?.attention).toEqual({
        attention: "background",
        write_lease: "none",
      });
      expect(reconciled?.takeover_owner_pid).toBeNull();
      expect(reconciled?.takeover_owner_process_token).toBeNull();
      await resumed.sendKeys("Enter");
      await resumed.waitForText(`ECHO:${marker}`, TIMEOUT).catch((error) => {
        throw new Error(
          `${error}\nTRACE\n${readFileSync(fixture.tracePath, "utf8")}\nSTDERR\n${readFileSync(fixture.stderrPath, "utf8")}`,
        );
      });
      await resumed.sendText(`RECLAIMED_${backend.toUpperCase()}`);
      await resumed
        .waitForText(`ECHO:RECLAIMED_${backend.toUpperCase()}`, TIMEOUT)
        .catch(async (error) => {
          throw new Error(
            `${error}\nTRACE\n${readFileSync(fixture.tracePath, "utf8")}\nSTDERR\n${readFileSync(fixture.stderrPath, "utf8")}`,
          );
        });
      await resumed.sendHexBytes(["1d", "64"]);
      await resumed.waitForText("Background processes", TIMEOUT);
      const detached = terminalRecords(fixture.home).find(
        (record) => record.lifecycle === "running",
      );
      expect(detached?.attention).toEqual({
        attention: "background",
        write_lease: "none",
      });
      expect(detached?.takeover_owner_pid).toBeNull();
      expect(detached?.takeover_owner_process_token).toBeNull();
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    60_000,
  );
}

test.skipIf(!tmuxAvailable())(
  "takeover host loss returns through the manager to the exact inline draft",
  async () => {
    const fixture = createFixture("fx-tui-terminal-takeover-loss-");
    const scriptPath = writeTakeoverFixture(fixture);
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TRACE_SCOPES:
        "terminal,terminal_takeover,terminal_client,terminal_store,terminal_host",
    });

    await active.sendText(`!${scriptPath}`);
    await active.waitForText("Running ", TIMEOUT);
    await active.sendLiteralText("TAKEOVER_LOSS_INLINE_DRAFT");
    await active.sendKeys("C-x");
    await waitForBackgroundProcessManager(active);
    await active.sendKeys("Enter");
    await active.waitForText("TAKEOVER_TOP", TIMEOUT);

    const identityPath = join(
      fixture.home,
      ".fx",
      "terminal-host",
      "host.json",
    );
    const identity = JSON.parse(
      await waitForTrace(identityPath, '"pid"'),
    ) as { pid: string };
    const hostPid = Number(identity.pid);
    expect(Number.isSafeInteger(hostPid)).toBe(true);
    process.kill(hostPid, "SIGKILL");

    const manager = await active.waitForText("Background processes", TIMEOUT);
    expect(manager).toContain("Agents & processes");
    await active.sendKeys("C-x");
    await active.waitForText("TAKEOVER_LOSS_INLINE_DRAFT", TIMEOUT);
    expect(readFileSync(fixture.tracePath, "utf8")).not.toContain(
      "input dropped",
    );
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "terminal action-specific schema rejects mixed input before starting a session",
  async () => {
    const fixture = createFixture("fx-tui-terminal-action-schema-");
    const mixedMarker = join(fixture.workspace, "mixed-start-ran");
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("terminal_mixed_start", "terminal", {
        request: {
          action: "start",
          cwd: fixture.workspace,
          command: `printf SHOULD_NOT_RUN > ${JSON.stringify(mixedMarker)}`,
          backend: "native",
          session_id: "terminal-foreign",
          cursor_segment: 1,
          cursor_offset: 0,
          after_event_id: 0,
          acknowledge_event_id: 1,
          max_events: 1,
          write: { kind: "text", text: "wrong action" },
          lease: "use",
          monitor: { kind: "remove", monitor_id: "monitor-foreign" },
          task_id: "task-foreign",
          workspace_root: fixture.workspace,
          rows: 24,
          columns: 80,
          signal: "terminate",
          close_policy: "force",
          profile: "user",
          shell: { kind: "user_login" },
          sections: null,
          unknown_zeta: true,
        },
      }),
      (body) => {
        const correction = JSON.parse(
          toolResultText(body, "terminal_mixed_start"),
        ) as {
          error: {
            code: string;
            action: string;
            invalid_fields: string[];
            missing_fields: string[];
            allowed_fields: string[];
            conflicts: string[][];
            retryable?: boolean;
          };
        };
        expect(correction.error).toEqual({
          code: "invalid_action_fields",
          action: "start",
          invalid_fields: [
            "session_id",
            "cursor_segment",
            "cursor_offset",
            "after_event_id",
            "acknowledge_event_id",
            "max_events",
            "write",
            "lease",
            "monitor",
            "task_id",
            "workspace_root",
            "rows",
            "columns",
            "signal",
            "close_policy",
            "sections",
            "unknown_zeta",
          ],
          missing_fields: [],
          allowed_fields: [
            "action",
            "cwd",
            "command",
            "profile",
            "shell",
            "backend",
            "return_when",
            "wait_ceiling_ms",
            "dimensions",
            "initial_monitors",
          ],
          conflicts: [["profile", "shell"]],
        });
        expect(terminalRecords(fixture.home)).toEqual([]);
        expect(existsSync(mixedMarker)).toBe(false);
        return fakeGatewayToolCall("terminal_valid_start", "terminal", {
          request: {
            action: "start",
            cwd: fixture.workspace,
            command: "printf ACTION_SCHEMA_OK",
            profile: null,
            shell: {
              kind: "executable",
              path: TERMINAL_FIXTURE_SHELL,
              clean_start: true,
            },
            backend: "native",
            return_when: { kind: "exit" },
            wait_ceiling_ms: 20_000,
            dimensions: null,
            initial_monitors: null,
          },
        });
      },
      (body) => {
        const resultText = toolResultText(body, "terminal_valid_start");
        const result = JSON.parse(resultText) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        return fakeGatewayToolCall("terminal_valid_close", "terminal", {
          request: {
            action: "close",
            session_id: terminalSessionId,
            close_policy: "force",
          },
        });
      },
      (body) => {
        const result = toolResultText(body, "terminal_valid_close");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("Terminal action schema verified");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Verify the terminal action schema.");
    await active.waitForText("Terminal action schema verified", TIMEOUT);
    expect(gateway.requests).toHaveLength(4);

    type JsonSchema = {
      type?: string;
      properties?: Record<string, JsonSchema>;
      enum?: string[];
      anyOf?: JsonSchema[];
      oneOf?: JsonSchema[];
      required?: string[];
      additionalProperties?: boolean;
      description?: string;
    };
    const firstRequest = JSON.parse(gateway.requests[0]!.body) as {
      tools: Array<{
        name?: string;
        inputSchema?: JsonSchema;
      }>;
    };
    const terminalSchema = firstRequest.tools.find(
      (tool) => tool.name === "terminal",
    )?.inputSchema;
    expect(terminalSchema).toBeDefined();
    expect(terminalSchema!.type).toBe("object");
    expect(terminalSchema!.oneOf).toBeUndefined();
    expect(terminalSchema!.additionalProperties).toBe(false);
    const properties = terminalSchema!.properties ?? {};
    expect(Object.keys(properties)).toEqual(["request"]);
    expect(terminalSchema!.required).toEqual(["request"]);
    const branches = properties.request!.oneOf ?? [];
    expect(branches).toHaveLength(12);
    const branchByAction = new Map(branches.map((branch) => [
      branch.properties?.action?.enum?.[0],
      branch,
    ]));
    expect([...branchByAction.keys()]).toEqual([
      "exec", "start", "read", "screen", "write", "wait",
      "monitor", "inspect", "list", "resize", "signal", "close",
    ]);
    for (const branch of branches) {
      expect(branch.type).toBe("object");
      expect(branch.additionalProperties).toBe(false);
    }
    const startProperties = branchByAction.get("start")!.properties!;
    expect(startProperties.wait_ceiling_ms!.anyOf![0]!.type).toBe("integer");
    expect(startProperties.shell!.anyOf![0]!.type).toBe("object");
    expect(startProperties.initial_monitors!.anyOf![0]!.type).toBe("array");
    expect(startProperties.return_when!.description).toContain(
      "required for every wait",
    );
    expect(startProperties.return_when!.description).toContain(
      "output_contains is monitor-only",
    );
    const readProperties = branchByAction.get("read")!.properties!;
    expect(Object.keys(readProperties)).toEqual([
      "action", "session_id", "cursor_segment", "cursor_offset",
    ]);
    expect(readProperties.cwd).toBeUndefined();
    expect(readProperties.cursor_segment!.description).toContain(
      "required for every read",
    );
    expect(readProperties.cursor_segment!.description).toContain(
      "raw_gap.available_from",
    );
    const closeProperties = branchByAction.get("close")!.properties!;
    expect(closeProperties.close_policy!.type).toBe("string");
    expect(closeProperties.close_policy!.description).toContain("Close is final");

    const mixedInput = toolCallInput(
      gateway.requests[1]!.body,
      "terminal_mixed_start",
    );
    expect(mixedInput.request).toEqual(expect.objectContaining({
      action: "start",
      session_id: "terminal-foreign",
    }));
    const validStartInput = toolCallInput(
      gateway.requests[2]!.body,
      "terminal_valid_start",
    );
    expect(validStartInput.request).toEqual(expect.objectContaining({
      action: "start",
    }));
    const validCloseInput = toolCallInput(
      gateway.requests[3]!.body,
      "terminal_valid_close",
    );
    expect(validCloseInput).toEqual({
      request: {
        action: "close",
        session_id: terminalSessionId,
        close_policy: "force",
      },
    });

    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Failed printf SHOULD_NOT_RUN");
    expect(scrollback).toContain("17 inv");
    expect(countOccurrences(scrollback, "Started printf ACTION_SCHEMA_OK")).toBe(1);
    expect(scrollback).toContain("Killed printf ACTION_SCHEMA_OK");
    expect(scrollback).not.toContain("Using terminal");
    expect(scrollback).not.toContain("Used terminal");
    expect(scrollback).not.toContain("Preparing command");
    await active.sendKeys("C-o");
    await active.sendKeys("PPage");
    const expanded = await active.waitForText("missing_fields", TIMEOUT);
    expect(expanded).toContain("missing_fields");
    expect(expanded).toContain("allowed_fields");
    expect(expanded).toContain("conflicts");
    await active.sendKeys("Escape");
    expect(existsSync(mixedMarker)).toBe(false);
    const records = terminalRecords(fixture.home);
    expect(records).toHaveLength(1);
    expect(records[0]!.session_id).toBe(terminalSessionId);
    expect(records[0]!.lifecycle).toBe("closed");
    const terminalPid = Number(records[0]!.pid);
    expect(Number.isSafeInteger(terminalPid) && terminalPid > 0).toBe(true);
    await waitForOwnedProcessExit([terminalPid]);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "terminal exec treats textual null placeholders as absent fields",
  async () => {
    const fixture = createFixture("fx-tui-terminal-null-placeholder-");
    const marker = join(fixture.workspace, "null-placeholder-ran");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("terminal_null_placeholder_exec", "terminal", {
        action: "exec",
        command: `printf NULL_PLACEHOLDER_OK > ${JSON.stringify(marker)}`,
        cwd: "null",
        profile: "null",
        session_id: "null",
        shell: "null",
        backend: "null",
        return_when: "null",
        wait_ceiling_ms: "null",
        dimensions: "null",
        initial_monitors: "null",
        cursor_segment: "null",
        cursor_offset: "null",
        after_event_id: "null",
        acknowledge_event_id: "null",
        max_events: "null",
        write: "null",
        lease: "null",
        monitor: "null",
        task_id: "NULL",
        workspace_root: " null ",
        rows: "null",
        columns: "null",
        signal: "null",
        close_policy: "null",
      }),
      (body) => {
        const result = toolResultText(body, "terminal_null_placeholder_exec");
        expect(result).not.toContain("invalid_action_fields");
        expect(readFileSync(marker, "utf8")).toBe("NULL_PLACEHOLDER_OK");
        return fakeGatewayFinalText("Terminal null placeholders verified");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Run the fixture command exactly once.");
    await active.waitForText("Terminal null placeholders verified", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);

    const scrollback = await active.captureFullScrollback();
    expect(countOccurrences(scrollback, "Ran printf NULL_PLACEHOLDER_OK")).toBe(1);
    expect(scrollback).not.toContain("invalid field");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "terminal repeated unknown correction with a valid neighbor stops without request three",
  async () => {
    const fixture = createFixture("fx-tui-terminal-correction-loop-");
    const firstBatch = [
      {
        id: "terminal_s_1",
        input: {
          request: {
            action: "inspect",
            session_id: "terminal-a",
            sections: null,
          },
        },
      },
      {
        id: "terminal_t_1",
        input: { request: { action: "list" } },
      },
    ];
    const secondBatch = [
      {
        id: "terminal_s_2",
        input: {
          request: {
            sections: null,
            session_id: "terminal-b",
            action: "inspect",
          },
        },
      },
      {
        id: "terminal_t_2",
        input: { request: { action: "list" } },
      },
    ];
    const gateway = startFakeGateway([
      fakeTerminalToolBatch(firstBatch),
      (body) => {
        const correction = JSON.parse(
          toolResultText(body, "terminal_s_1"),
        ).error;
        expect(correction.code).toBe("invalid_action_fields");
        expect(correction.action).toBe("inspect");
        expect(correction.invalid_fields).toEqual(["sections"]);
        expect(correction.allowed_fields).toEqual([
          "action",
          "session_id",
          "after_event_id",
          "acknowledge_event_id",
          "max_events",
        ]);
        expect(JSON.parse(toolResultText(body, "terminal_t_1")).success.list)
          .toBeDefined();
        return fakeTerminalToolBatch(secondBatch);
      },
      () => {
        throw new Error("terminal correction loop issued request three");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TRACE_SCOPES:
        "input,terminal,terminal_client,terminal_store,terminal_host,agent,worker,gateway,tool,permission",
    });

    await active.sendText("Exercise repeated terminal validation corrections.");
    const pane = await active.waitForText(
      "Repeated terminal validation failures stopped the tool loop",
      TIMEOUT,
    );
    expect(pane).toContain("no terminal effect");
    expect(gateway.requests).toHaveLength(2);
    expect(terminalRecords(fixture.home)).toEqual([]);

    const committed = sessionEventLogs(fixture.home)
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as any)
      .find((event) =>
        event.kind === "history_turn_committed" &&
        event.payload?.turn?.execution?.tool_steps?.some((step: any) =>
          step.tool_calls?.some((call: any) => call.id === "terminal_s_2")
        )
      );
    expect(committed).toBeDefined();
    const secondStep = committed.payload.turn.execution.tool_steps.find(
      (step: any) =>
        step.tool_calls?.some((call: any) => call.id === "terminal_s_2"),
    );
    const secondInspect = secondStep.tool_results.find(
      (result: any) => result.tool_call_id === "terminal_s_2",
    );
    const secondList = secondStep.tool_results.find(
      (result: any) => result.tool_call_id === "terminal_t_2",
    );
    expect(secondInspect.status).toBe("failure");
    expect(JSON.parse(secondInspect.output).error).toEqual({
      code: "invalid_action_fields",
      action: "inspect",
      invalid_fields: ["sections"],
      missing_fields: [],
      allowed_fields: [
        "action",
        "session_id",
        "after_event_id",
        "acknowledge_event_id",
        "max_events",
      ],
      conflicts: [],
    });
    expect(secondList.status).toBe("success");
    expect(JSON.parse(secondList.output).success.list).toBeDefined();

    const trace = readFileSync(fixture.tracePath, "utf8");
    for (const callId of ["terminal_s_1", "terminal_s_2"]) {
      expect(trace).not.toMatch(
        new RegExp(`event=permission_requested[^\\n]*call_id=${callId}\\b`),
      );
      expect(trace).not.toMatch(
        new RegExp(`event=before_tool_execution[^\\n]*call_id=${callId}\\b`),
      );
    }
    for (const callId of ["terminal_t_1", "terminal_t_2"]) {
      expect(trace).toMatch(
        new RegExp(`event=permission_requested[^\\n]*call_id=${callId}\\b`),
      );
      expect(trace).toMatch(
        new RegExp(`event=before_tool_execution[^\\n]*call_id=${callId}\\b`),
      );
    }
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI starts and gracefully closes an interactive terminal when the command is exact empty",
  async () => {
    const fixture = createFixture("fx-tui-terminal-empty-command-");
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_empty_start", "terminal", {
        action: "start",
        command: "",
      }),
      (body) => {
        const resultText = toolResultText(body, "tui_terminal_empty_start");
        const result = JSON.parse(resultText) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        expect(resultText).toContain('"lifecycle":"running"');
        return fakeGatewayToolCall("tui_terminal_empty_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "graceful",
        });
      },
      (body) => {
        const result = toolResultText(body, "tui_terminal_empty_close");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("Interactive terminal started and closed");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Start a terminal.");
    const pane = await active.waitForText(
      "Interactive terminal started and closed",
      TIMEOUT,
    );
    expect(pane).toContain("Started interactive shell");
    expect(pane).toContain("Closed interactive shell");
    expect(pane).not.toContain("InvalidCommand");
    expect(pane).not.toContain("Failed start");
    expect(gateway.requests).toHaveLength(3);

    const record = await waitForTerminalRecord(
      fixture.home,
      (candidate) =>
        candidate.session_id === terminalSessionId &&
        candidate.lifecycle === "closed",
    );
    const terminalPid = Number(record.pid);
    expect(Number.isSafeInteger(terminalPid) && terminalPid > 0).toBe(true);
    await waitForOwnedProcessExit([terminalPid]);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI normalizes gateway start composites, explains external monitor rejection, and preserves local monitor flow",
  async () => {
    const fixture = createFixture("fx-tui-terminal-monitor-path-scope-");
    const outsidePath = join(fixture.root, "outside-ready");
    const localPath = join(fixture.workspace, "local-ready");
    const rejectedMarker = join(fixture.workspace, "rejected-start-ran");
    writeFileSync(outsidePath, "ready");
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("terminal_external_path", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command: `printf SHOULD_NOT_RUN > ${JSON.stringify(rejectedMarker)}`,
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: JSON.stringify({ kind: "started" }),
        initial_monitors: JSON.stringify([{
          condition: {
            kind: "path_exists",
            path: outsidePath,
            check_interval_ms: 25,
          },
          notify: { kind: "on_match" },
          lifetime: { kind: "until_match" },
        }]),
      }),
      (body) => {
        const result = toolResultText(body, "terminal_external_path");
        expect(result).toContain('"code":"path_outside_workspace"');
        expect(terminalRecords(fixture.home)).toEqual([]);
        expect(existsSync(rejectedMarker)).toBe(false);
        expect(sessionEventLogs(fixture.home)).toContain("path_outside_workspace");
        const identity = JSON.parse(
          readFileSync(
            join(fixture.home, ".fx", "terminal-host", "host.json"),
            "utf8",
          ),
        ) as { pid: string };
        expect(directChildPids(Number(identity.pid))).toEqual([]);
        return fakeGatewayToolCall("terminal_local_path", "terminal", {
          action: "start",
          cwd: fixture.workspace,
          command: holdUntilCleanup(fixture.root),
          shell: {
            kind: "executable",
            path: TERMINAL_FIXTURE_SHELL,
            clean_start: true,
          },
          backend: "native",
          return_when: { kind: "started" },
          dimensions: { rows: 24, columns: 80 },
          initial_monitors: [{
            condition: { kind: "path_exists", path: localPath },
            check_interval_ms: 25,
            notify: { kind: "on_match" },
            lifetime: { kind: "until_match" },
          }],
        });
      },
      async (body) => {
        const result = JSON.parse(
          toolResultText(body, "terminal_local_path"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        writeFileSync(localPath, "ready");
        await Bun.sleep(150);
        return fakeGatewayToolCall("terminal_local_inspect", "terminal", {
          action: "inspect",
          session_id: terminalSessionId,
          after_event_id: 0,
          max_events: 16,
        });
      },
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "terminal_local_inspect"),
        ) as {
          success: {
            inspect: {
              events: Array<{ monitor_id: string; reason: string }>;
            };
          };
        };
        expect(result.success.inspect.events.some((event) =>
          event.monitor_id === "monitor-1" && event.reason === "matched"
        )).toBe(true);
        return fakeGatewayToolCall("terminal_local_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        });
      },
      (body) => {
        const result = toolResultText(body, "terminal_local_close");
        expect(result).toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("Terminal monitor path scope verified");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Verify terminal monitor workspace paths.");
    const pane = await active.waitForText(
      "Terminal monitor path scope verified",
      TIMEOUT,
    );
    expect(pane).toContain("Failed printf SHOULD_NOT_RUN");
    expect(pane).toContain("Started while [ ! -e");
    expect(pane).toContain("Inspected while [ ! -e");
    expect(pane).toContain("Killed while [ ! -e");
    expect(gateway.requests).toHaveLength(5);
    expect(gateway.requests[1]!.body).toContain("path_outside_workspace");
    expect(existsSync(rejectedMarker)).toBe(false);

    const record = await waitForTerminalRecord(
      fixture.home,
      (candidate) =>
        candidate.session_id === terminalSessionId &&
        candidate.lifecycle === "closed",
    );
    const terminalPid = Number(record.pid);
    expect(Number.isSafeInteger(terminalPid) && terminalPid > 0).toBe(true);
    await waitForOwnedProcessExit([terminalPid]);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI auto mode reviews terminal start but not owner-scoped list",
  async () => {
    const fixture = createFixture("fx-tui-terminal-public-");
    let startedSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command: "printf TUI_PUBLIC_TERMINAL_NATIVE",
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: { kind: "exit" },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        startedSessionId = result.success.start.session.session_id;
        expect(startedSessionId.length).toBeGreaterThan(0);
        return fakeGatewayToolCall("tui_terminal_list", "terminal", {
          action: "list",
          backend: "native",
        });
      },
      fakeGatewayFinalText("TUI public terminal complete"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_PERMISSION_MODE: "auto",
      FX_TRACE_SCOPES:
        "input,terminal,terminal_client,terminal_store,terminal_host,agent,worker,gateway,permission",
    });

    await active.sendText("Run and list the native terminal fixture.");
    const pane = await active.waitForText("TUI public terminal complete", TIMEOUT);
    if (pane.includes("Failed printf TUI_PUBLIC_TERMINAL_NATIVE") || pane.includes("Failed terminal sessions")) {
      throw new Error(
        `start=${toolResultText(gateway.requests[1]!.body, "tui_terminal_start")}\n` +
          `list=${toolResultText(gateway.requests[2]!.body, "tui_terminal_list")}\n` +
          `TRACE\n${readFileSync(fixture.tracePath, "utf8")}`,
      );
    }
    expect(pane).toContain("Started printf TUI_PUBLIC_TERMINAL_NATIVE");
    expect(pane).toContain("Listed terminal sessions");
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[1]!.body).toContain("tui_terminal_start");
    expect(gateway.requests[1]!.body).toContain('\\"backend\\":\\"native\\"');
    expect(gateway.requests[2]!.body).toContain("tui_terminal_list");
    const listResult = toolResultText(
      gateway.requests[2]!.body,
      "tui_terminal_list",
    );
    const parsedList = JSON.parse(listResult) as {
      success: { list: { sessions: Array<{ session_id: string }> } };
    };
    expect(parsedList.success.list.sessions.map((session) => session.session_id))
      .toEqual([startedSessionId]);
    expect(listResult).toContain('"lifecycle":"exited"');
    expect(listResult).not.toContain("owner_authority");
    expect(listResult).not.toContain("proof");
    expect(gateway.classifierRequests).toHaveLength(1);
    expect(classifierEvidenceFromRequest(gateway.classifierRequests[0]!.body))
      .toContain('"action":"start"');
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI terminal write lease payload contract rejects combined acquire and delivers after valid acquisition",
  async () => {
    const fixture = createFixture("fx-tui-terminal-lease-payload-");
    const payload = "LEASE_PAYLOAD_INPUT\n";
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_lease_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command:
          "printf 'TUI_PUBLIC_LEASE_PAYLOAD_READY\\n'; " +
          "while IFS= read -r line; do " +
          "printf 'TUI_PUBLIC_LEASE_PAYLOAD_ECHO:%s\\n' \"$line\"; done",
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: {
          kind: "match",
          pattern: "TUI_PUBLIC_LEASE_PAYLOAD_READY",
        },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_lease_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        return fakeGatewayToolCall(
          "tui_terminal_lease_invalid_acquire",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "acquire",
            write: { kind: "text", text: payload },
          },
        );
      },
      (body) => {
        expect(
          toolResultText(body, "tui_terminal_lease_invalid_acquire"),
        ).toContain("InvalidWritePayload");
        return fakeGatewayToolCall(
          "tui_terminal_lease_premature_use",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "use",
            write: { kind: "text", text: payload },
          },
        );
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_lease_premature_use"))
          .toContain('"code":"lease_conflict"');
        return fakeGatewayToolCall("tui_terminal_lease_read_before", "terminal", {
          action: "read",
          session_id: terminalSessionId,
          cursor_segment: 1,
          cursor_offset: 0,
        });
      },
      (body) => {
        const output = toolResultText(body, "tui_terminal_lease_read_before");
        expect(output).toContain("TUI_PUBLIC_LEASE_PAYLOAD_READY");
        expect(output).not.toContain("TUI_PUBLIC_LEASE_PAYLOAD_ECHO");
        return fakeGatewayToolCall("tui_terminal_lease_acquire", "terminal", {
          action: "write",
          session_id: terminalSessionId,
          lease: "acquire",
        });
      },
      (body) => {
        const acquired = toolResultText(body, "tui_terminal_lease_acquire");
        expect(acquired).toContain('"write_lease":"agent"');
        expect(acquired).toContain('"accepted_bytes":0');
        return fakeGatewayToolCall("tui_terminal_lease_use", "terminal", {
          action: "write",
          session_id: terminalSessionId,
          lease: "use",
          write: { kind: "text", text: payload },
        });
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_lease_use"))
          .toContain('"accepted_bytes":20');
        return fakeGatewayToolCall("tui_terminal_lease_wait", "terminal", {
          action: "wait",
          session_id: terminalSessionId,
          return_when: {
            kind: "match",
            pattern: "TUI_PUBLIC_LEASE_PAYLOAD_ECHO:LEASE_PAYLOAD_INPUT",
          },
          wait_ceiling_ms: 20_000,
        });
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_lease_wait"))
          .toContain('"outcome":{"condition_met":{}}');
        return fakeGatewayToolCall("tui_terminal_lease_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        });
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_lease_close"))
          .toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("TUI terminal lease payload complete");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Exercise terminal lease and payload validation.");
    const pane = await active.waitForText(
      "TUI terminal lease payload complete",
      TIMEOUT,
    );
    expect(pane).toContain("Failed printf 'TUI_PUBLIC_LEASE_PAYLOAD_READY");
    expect(pane).toContain("Acquired control of");
    expect(pane).toContain("Sent input to");
    expect(pane).toContain("Finished waiting for");
    expect(pane).toContain("Killed printf 'TUI_PUBLIC_LEASE_PAYLOAD_READY");
    expect(gateway.requests).toHaveLength(9);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI public terminal controls reject encoded bytes and deliver key designators",
  async () => {
    const fixture = createFixture("fx-tui-terminal-public-controls-");
    const bytePath = join(fixture.root, "control-byte.txt");
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_controls_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command:
          "printf 'TUI_PUBLIC_CONTROLS_READY\\n'; stty raw -echo; " +
          `od -An -tu1 -N1 | tr -d '[:space:]' > ${JSON.stringify(bytePath)}; ` +
          "printf '\\nTUI_PUBLIC_CONTROLS_DONE\\n'; " +
          holdUntilCleanup(fixture.root),
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: { kind: "match", pattern: "TUI_PUBLIC_CONTROLS_READY" },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_controls_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        return fakeGatewayToolCall(
          "tui_terminal_controls_acquire",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "acquire",
          },
        );
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_controls_acquire"))
          .toContain('"write_lease":"agent"');
        return fakeGatewayToolCall(
          "tui_terminal_controls_encoded_byte",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "use",
            write: { kind: "controls", controls: [12] },
          },
        );
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_controls_encoded_byte"))
          .toContain("InvalidWritePayload");
        return fakeGatewayToolCall(
          "tui_terminal_controls_designator",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "use",
            write: { kind: "controls", controls: [108] },
          },
        );
      },
      async (body) => {
        expect(toolResultText(body, "tui_terminal_controls_designator"))
          .toContain('"accepted_bytes":1');
        expect((await waitForTrace(bytePath, "12")).trim()).toBe("12");
        return fakeGatewayToolCall("tui_terminal_controls_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        });
      },
      (body) => {
        expect(toolResultText(body, "tui_terminal_controls_close"))
          .toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("TUI public terminal controls complete");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Exercise public terminal Ctrl+L input.");
    const pane = await active.waitForText(
      "TUI public terminal controls complete",
      TIMEOUT,
    );
    expect(pane).toContain("Failed printf 'TUI_PUBLIC_CONTROLS_READY");
    expect(pane).toContain("Acquired control of");
    expect(pane).toContain("Sent input to");
    expect(pane).toContain("Killed printf 'TUI_PUBLIC_CONTROLS_READY");
    expect(gateway.requests).toHaveLength(6);
    expect(readFileSync(bytePath, "utf8").trim()).toBe("12");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI public signal reaches a foreground job outside the shell process group",
  async () => {
    const fixture = createFixture("fx-tui-terminal-public-signal-");
    const proofPath = join(fixture.root, "foreground-signal.proof");
    const termPath = join(fixture.root, "foreground-signal.term");
    const scriptPath = join(fixture.workspace, "foreground-signal.sh");
    writeFileSync(
      scriptPath,
      `#!${TERMINAL_FIXTURE_SHELL}
trap 'printf term > ${JSON.stringify(termPath)}; exit 0' TERM
printf '%s %s %s\n' "$$" "$PPID" "$(ps -o pgid= -p $$ | tr -d ' ')" > ${JSON.stringify(proofPath)}
printf 'TUI_PUBLIC_SIGNAL_READY\n'
${holdUntilCleanup(fixture.root)}
`,
    );
    chmodSync(scriptPath, 0o700);

    let terminalSessionId = "";
    let targetPid = 0;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_signal_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command: JSON.stringify(scriptPath),
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: {
          kind: "match",
          pattern: "TUI_PUBLIC_SIGNAL_READY",
        },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      async (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_signal_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        await waitForTrace(proofPath, " ");
        const [pidText, parentText, pgidText] = readFileSync(proofPath, "utf8")
          .trim()
          .split(/\s+/);
        targetPid = Number(pidText);
        const targetParentPid = Number(parentText);
        const targetPgid = Number(pgidText);
        const record = await waitForTerminalRecord(
          fixture.home,
          (candidate) => candidate.session_id === terminalSessionId,
        );
        const shellPid = Number(record.pid);
        expect(targetPid).toBeGreaterThan(0);
        expect(targetParentPid).toBe(shellPid);
        expect(targetPgid).toBe(processGroupId(targetPid));
        expect(targetPgid).not.toBe(processGroupId(shellPid));
        return fakeGatewayToolCall("tui_terminal_signal", "terminal", {
          action: "signal",
          session_id: terminalSessionId,
          signal: "terminate",
        });
      },
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_signal"),
        ) as { success: { signal: { signal: string } } };
        expect(result.success.signal.signal).toBe("terminate");
        return fakeGatewayFinalText("TUI public terminal signal complete");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Signal the foreground terminal fixture.");
    const pane = await active.waitForText(
      "TUI public terminal signal complete",
      TIMEOUT,
    );
    expect(pane).toContain("Started");
    expect(pane).toContain("foreground-signal.sh");
    expect(pane).toContain("Sent terminate to");
    expect(gateway.requests).toHaveLength(3);
    await waitForSignalMarker(termPath);
    await waitForOwnedProcessExit([targetPid]);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI public terminal waits with the advertised ceiling on one native session",
  async () => {
    const fixture = createFixture("fx-tui-terminal-public-wait-");
    const marker = "TUI_PUBLIC_WAIT_MARKER";
    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("tui_terminal_wait_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command:
          "printf 'TUI_PUBLIC_WAIT_READY\\n'; while IFS= read -r line; do printf 'TUI_PUBLIC_WAIT:%s\\n' \"$line\"; done",
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: { kind: "match", pattern: "TUI_PUBLIC_WAIT_READY" },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "tui_terminal_wait_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        return fakeGatewayToolCall(
          "tui_terminal_wait_acquire",
          "terminal",
          {
            action: "write",
            session_id: terminalSessionId,
            lease: "acquire",
          },
        );
      },
      (body) => {
        const result = toolResultText(body, "tui_terminal_wait_acquire");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"write_lease":"agent"');
        return fakeGatewayToolCall("tui_terminal_wait_write", "terminal", {
          action: "write",
          session_id: terminalSessionId,
          lease: "use",
          write: { kind: "text", text: `${marker}\n` },
        });
      },
      (body) => {
        const result = toolResultText(body, "tui_terminal_wait_write");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"accepted_bytes":');
        return fakeGatewayToolCall("tui_terminal_wait_wait", "terminal", {
          action: "wait",
          session_id: terminalSessionId,
          return_when: {
            kind: "match",
            pattern: `TUI_PUBLIC_WAIT:${marker}`,
          },
          wait_ceiling_ms: 20_000,
        });
      },
      (body) => {
        const result = toolResultText(body, "tui_terminal_wait_wait");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"outcome":{"condition_met":{}}');
        return fakeGatewayToolCall("tui_terminal_wait_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        });
      },
      (body) => {
        const result = toolResultText(body, "tui_terminal_wait_close");
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        return fakeGatewayFinalText("TUI public terminal wait complete");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Exercise the public terminal wait contract.");
    await active.waitForText("TUI public terminal wait complete", TIMEOUT);
    expect(gateway.requests).toHaveLength(6);
    type WaitSchema = {
      type?: string;
      properties?: Record<string, WaitSchema>;
      enum?: string[];
      oneOf?: WaitSchema[];
      required?: string[];
      additionalProperties?: boolean;
    };
    const request = JSON.parse(gateway.requests[0]!.body) as {
      tools: Array<{
        name?: string;
        inputSchema?: WaitSchema;
      }>;
    };
    const terminalSchema = request.tools.find(
      (tool) => tool.name === "terminal",
    )?.inputSchema;
    expect(terminalSchema).toBeDefined();
    expect(terminalSchema!.type).toBe("object");
    expect(terminalSchema!.oneOf).toBeUndefined();
    expect(terminalSchema!.additionalProperties).toBe(false);
    expect(terminalSchema!.required).toEqual(["request"]);
    const branches = terminalSchema!.properties?.request?.oneOf ?? [];
    const waitBranch = branches.find((branch) =>
      branch.properties?.action?.enum?.[0] === "wait"
    );
    expect(waitBranch).toBeDefined();
    const waitProperties = Object.keys(waitBranch!.properties ?? {});
    expect(waitProperties).toEqual([
      "action", "session_id", "return_when", "wait_ceiling_ms",
    ]);
    expect(waitBranch!.required).toEqual(waitProperties);
    expect(waitProperties).not.toContain("safety_ceiling_ms");
    expect(waitProperties).not.toContain("authority");
    expect(waitProperties).not.toContain("proof");
    expect(gateway.requests[4]!.body).toContain('"wait_ceiling_ms":20000');
    expect(gateway.requests[4]!.body).not.toContain("safety_ceiling_ms");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TUI public event monitor ignores a materialized check interval and acknowledges one event",
  async () => {
    const fixture = createFixture("fx-tui-terminal-public-monitor-");

    const marker = "TUI_PUBLIC_MONITOR_MARKER";
    let terminalSessionId = "";
    let eventId = 0;
    const callIds = [
      "tui_terminal_monitor_start",
      "tui_terminal_monitor_add",
      "tui_terminal_monitor_acquire",
      "tui_terminal_monitor_write",
      "tui_terminal_monitor_wait",
      "tui_terminal_monitor_inspect",
      "tui_terminal_monitor_acknowledge",
      "tui_terminal_monitor_close",
    ];
    const gateway = startFakeGateway([
      fakeGatewayToolCall(callIds[0]!, "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command:
          "printf 'TUI_PUBLIC_MONITOR_READY\\n'; while IFS= read -r line; do printf 'TUI_PUBLIC_MONITOR:%s\\n' \"$line\"; done",
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: {
          kind: "match",
          pattern: "TUI_PUBLIC_MONITOR_READY",
        },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(toolResultText(body, callIds[0]!)) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        expect(terminalSessionId.length).toBeGreaterThan(0);
        return fakeGatewayToolCall(callIds[1]!, "terminal", {
          action: "monitor",
          session_id: terminalSessionId,
          monitor: {
            kind: "add",
            monitor_id: "",
            definition: {
              condition: {
                kind: "output_contains",
                pattern: `TUI_PUBLIC_MONITOR:${marker}`,
                duration_ms: 1,
                exit_code: 0,
                signal: "terminate",
                host: "",
                port: 1,
                path: "",
                minimum_bytes: 0,
                command: "",
                cwd: "",
              },
              check_interval_ms: 1,
              notify: { kind: "on_match", count: 1, interval_ms: 1 },
              lifetime: { kind: "until_match", duration_ms: 1 },
            },
          },
        });
      },
      (body) => {
        const result = toolResultText(body, callIds[1]!);
        expect(result).toContain(`"session_id":"${terminalSessionId}"`);
        expect(result).toContain('"monitor_id":"monitor-1"');
        return fakeGatewayToolCall(callIds[2]!, "terminal", {
          action: "write",
          session_id: terminalSessionId,
          lease: "acquire",
        });
      },
      (body) => {
        const result = toolResultText(body, callIds[2]!);
        expect(result).toContain('"write_lease":"agent"');
        return fakeGatewayToolCall(callIds[3]!, "terminal", {
          action: "write",
          session_id: terminalSessionId,
          lease: "use",
          write: { kind: "text", text: `${marker}\n` },
        });
      },
      (body) => {
        const result = toolResultText(body, callIds[3]!);
        expect(result).toContain('"accepted_bytes":');
        return fakeGatewayToolCall(callIds[4]!, "terminal", {
          action: "wait",
          session_id: terminalSessionId,
          return_when: {
            kind: "match",
            pattern: `TUI_PUBLIC_MONITOR:${marker}`,
          },
          wait_ceiling_ms: 20_000,
        });
      },
      (body) => {
        const result = toolResultText(body, callIds[4]!);
        expect(result).toContain('"outcome":{"condition_met":{}}');
        return fakeGatewayToolCall(callIds[5]!, "terminal", {
          action: "inspect",
          session_id: terminalSessionId,
          after_event_id: 0,
          max_events: 16,
        });
      },
      (body) => {
        const result = JSON.parse(toolResultText(body, callIds[5]!)) as {
          success: {
            inspect: {
              events: Array<{
                event_id: number;
                monitor_id: string;
                reason: string;
              }>;
            };
          };
        };
        expect(result.success.inspect.events).toHaveLength(1);
        expect(result.success.inspect.events[0]).toMatchObject({
          monitor_id: "monitor-1",
          reason: "matched",
        });
        eventId = result.success.inspect.events[0]!.event_id;
        return fakeGatewayToolCall(callIds[6]!, "terminal", {
          action: "inspect",
          session_id: terminalSessionId,
          after_event_id: eventId,
          acknowledge_event_id: eventId,
          max_events: 16,
        });
      },
      (body) => {
        const result = JSON.parse(toolResultText(body, callIds[6]!)) as {
          success: { inspect: { events: unknown[] } };
        };
        expect(result.success.inspect.events).toEqual([]);
        return fakeGatewayToolCall(callIds[7]!, "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        });
      },
      (body) => {
        const result = toolResultText(body, callIds[7]!);
        expect(result).toContain('"lifecycle":"closed"');
        return fakeGatewayFinalText("TUI public terminal monitor complete");
      },
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Exercise the public event-driven terminal monitor.");
    const pane = await active.waitForText(
      "TUI public terminal monitor complete",
      TIMEOUT,
    );
    for (const label of [
      "Started",
      "Added monitor to",
      "Acquired control of",
      "Sent input to",
      "Finished waiting for",
      "Inspected",
      "Killed",
    ]) {
      expect(pane).toContain(label);
    }
    expect(gateway.requests).toHaveLength(9);
    expect(gateway.requests[2]!.body).toContain(
      '"kind":"output_contains"',
    );
    expect(gateway.requests[2]!.body).toContain(
      '"check_interval_ms":1',
    );
    for (const [index, callId] of callIds.entries()) {
      const result = toolResultText(gateway.requests[index + 1]!.body, callId);
      expect(result).not.toContain("owner_authority");
      expect(result).not.toContain('"proof"');
    }
    expect(eventId).toBeGreaterThan(0);
    expect(terminalRecords(fixture.home).some((record) =>
      record.session_id === terminalSessionId && record.lifecycle === "closed"
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "long HOME executes public native terminal start inspect read and close",
  async () => {
    const fixture = createFixture("fx-tui-terminal-long-home-", 141);
    const durableDir = join(fixture.home, ".fx", "terminal-host");
    const durableSocket = join(durableDir, "host.sock");
    const transport = terminalTransportPaths(fixture.home);
    expect(Buffer.byteLength(durableSocket)).toBe(141);
    expect(transport.dir).not.toBe(durableDir);

    let terminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("long_home_terminal_start", "terminal", {
        action: "start",
        cwd: fixture.workspace,
        command: "printf 'LONG_HOME_PUBLIC_READY\\n'; sleep 60",
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: { kind: "match", pattern: "LONG_HOME_PUBLIC_READY" },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
      }),
      (body) => {
        const result = JSON.parse(
          toolResultText(body, "long_home_terminal_start"),
        ) as {
          success: { start: { session: { session_id: string } } };
        };
        terminalSessionId = result.success.start.session.session_id;
        return fakeGatewayToolCall(
          "long_home_terminal_inspect",
          "terminal",
          { action: "inspect", session_id: terminalSessionId },
        );
      },
      () =>
        fakeGatewayToolCall("long_home_terminal_read", "terminal", {
          action: "read",
          session_id: terminalSessionId,
          cursor_segment: 1,
          cursor_offset: 0,
        }),
      () =>
        fakeGatewayToolCall("long_home_terminal_close", "terminal", {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        }),
      fakeGatewayFinalText("LONG HOME public terminal complete"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Exercise the public terminal across the long profile path.");
    const pane = await active.waitForText(
      "LONG HOME public terminal complete",
      TIMEOUT,
    );
    for (const label of ["Started", "Inspected", "Read output from", "Killed"]) {
      expect(pane).toContain(label);
    }
    expect(gateway.requests).toHaveLength(5);
    const inspectResult = toolResultText(
      gateway.requests[2]!.body,
      "long_home_terminal_inspect",
    );
    const readResult = toolResultText(
      gateway.requests[3]!.body,
      "long_home_terminal_read",
    );
    const closeResult = toolResultText(
      gateway.requests[4]!.body,
      "long_home_terminal_close",
    );
    expect(inspectResult).toContain(`\"session_id\":\"${terminalSessionId}\"`);
    expect(inspectResult).toContain('"lifecycle":"running"');
    expect(readResult).toContain("LONG_HOME_PUBLIC_READY");
    expect(readResult).toContain(`\"session_id\":\"${terminalSessionId}\"`);
    expect(closeResult).toContain('"lifecycle":"closed"');
    expect(closeResult).not.toContain("proof");

    expect(existsSync(durableSocket)).toBe(false);
    expect(existsSync(transport.socket)).toBe(true);
    expect(readdirSync(transport.dir)).toEqual(["host.sock"]);
    expect(terminalRecords(fixture.home).some((record) =>
      record.session_id === terminalSessionId
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "direct paste and image starts bypass the model and restore the manager inventory exactly",
  async () => {
    const fixture = createFixture("fx-tui-terminal-direct-");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    const pastedCommand =
      `!printf DIRECT_PASTE_READY; ${holdUntilCleanup(fixture.root)} #` +
      "x".repeat(1_050);
    await active.pasteText(pastedCommand);
    await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    await active.sendKeys("Enter");
    await active.waitForText("Starting:", TIMEOUT);
    await active.waitForText("Running ", TIMEOUT);
    const firstFooter = await active.capturePane();
    expect(firstFooter).not.toContain("background (");
    expect(firstFooter).not.toContain("ctrl+x manager");

    await active.sendText(`/image ${fixture.imagePath}`);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendKeys("Home");
    await active.sendLiteralText(
      `!printf DIRECT_IMAGE_READY; ${holdUntilCleanup(fixture.root)} #`,
    );
    await active.sendKeys("Enter");
    await active.waitForPane(
      (value) => countOccurrences(value, "Running ") >= 2,
      TIMEOUT,
    );
    const secondFooter = await active.capturePane();
    expect(secondFooter).not.toContain("background (");
    expect(secondFooter).not.toContain("ctrl+x manager");
    const trace = await waitForTrace(
      fixture.tracePath,
      "draft images dropped count=1 reason=direct_terminal",
    );

    await active.sendText("/images");
    await active.waitForText("no pending images", TIMEOUT);
    await active.sendLiteralText("DIRECT_MANAGER_RESTORED");
    await active.sendKeys("C-x");
    let manager = await active.waitForText("Background processes", TIMEOUT);
    expect(manager).toContain("DIRECT_PASTE_READY");
    expect(manager).toContain("DIRECT_IMAGE_READY");
    expect(manager).toContain(
      "↑↓ select   enter inspect   c new agent   t attach   r archives   ctrl-x close",
    );
    if (!/^› .*DIRECT_IMAGE_READY/m.test(manager)) {
      await active.sendKeys("Down");
    }
    manager = await active.waitForPane(
      (value) => /^› .*DIRECT_IMAGE_READY/m.test(value),
      TIMEOUT,
    );
    expect(manager).toContain("DIRECT_IMAGE_READY");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (value) =>
        value.includes("DIRECT_IMAGE_READY") &&
        !value.includes("Agents & processes"),
      TIMEOUT,
    );
    await active.sendHexBytes(["1d", "64"]);
    expect(await active.waitForText("Agents & processes", TIMEOUT)).toContain(
      "Background processes",
    );
    await active.sendKeys("Escape");
    expect(await active.waitForText("Agents & processes", TIMEOUT)).toContain(
      "r archives",
    );
    await active.resizeWindow(72, 12);
    await Bun.sleep(300);
    const resizedManager = await active.capturePane();
    expect(resizedManager).toMatch(/^› .*printf DIRECT_(?:IMAG|PAST)/m);
    expect(resizedManager).toContain("r archives   ctrl-x close");
    await active.resizeWindow(120, 30);
    await active.waitForText("Agents & processes", TIMEOUT);
    await active.sendKeys("C-x");
    await active.waitForText("DIRECT_MANAGER_RESTORED", TIMEOUT);

    await Bun.sleep(700);
    const scrollback = await active.captureFullScrollback();
    expect(countOccurrences(scrollback, "Starting:")).toBe(2);
    expect(countOccurrences(scrollback, "Running ")).toBe(2);
    expect(gateway.requests).toHaveLength(0);
    expect(trace).not.toContain("[gateway]");
    expect(trace).not.toContain("[worker]");
    expect(sessionRecords(fixture.home)).not.toHaveLength(0);
    for (const record of sessionRecords(fixture.home)) {
      expect(record.history_len).toBe(0);
    }
    const promptHistory = readFileSync(
      join(fixture.home, ".fx", "history.jsonl"),
      "utf8",
    );
    expect(promptHistory).toContain("/image ");
    expect(promptHistory).toContain("/images");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "post-admission direct command settles truthfully during immediate quit",
  async () => {
    const fixture = createFixture("fx-tui-terminal-direct-immediate-quit-");
    const tapePath = join(fixture.root, "immediate-quit.fxtape");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_RECORD: tapePath,
      FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS: "5000",
      FX_TERMINAL_TEST_GRACEFUL_EXIT_WAIT_CEILING_MS: "0",
      FX_TRACE_SCOPES: "terminal",
    });
    const commandRanPath = join(fixture.root, "immediate-command-ran");
    const command = `: > ${JSON.stringify(commandRanPath)}`;

    await active.sendText(`!${command}`);
    await active.waitForText(`Starting: ${command}`, TIMEOUT);
    const admitted = await waitForTerminalRecord(
      fixture.home,
      (record) => record.command === command && record.lifecycle === "starting",
    );
    expect(admitted.command).toBe(command);
    await active.sendText("/quit");
    await waitForTrace(fixture.tracePath, "direct graceful exit deferred");
    expect(active.isAlive()).toBe(true);
    await active.waitForText(`Running `, TIMEOUT);
    expect(active.isAlive()).toBe(true);
    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    expect(active.isAlive()).toBe(false);
    sessions.splice(sessions.indexOf(active), 1);

    const replay = Bun.spawnSync({
      cmd: [FX_BIN, "replay", tapePath],
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(replay.exitCode).toBe(0);
    expect(replay.stderr.toString()).toBe("");
    const replayGrid = replay.stdout.toString();
    expect(countOccurrences(replayGrid, `Starting: ${command}`)).toBe(1);
    expect(countOccurrences(replayGrid, `Running `)).toBe(1);
    expect(replayGrid).not.toContain(`Failed cancelled: ${command}`);
    expect(existsSync(commandRanPath)).toBe(true);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(fixture.tracePath, "utf8")).not.toContain("[gateway]");
    expect(readFileSync(fixture.tracePath, "utf8")).not.toContain("[worker]");
    for (const record of sessionRecords(fixture.home)) {
      expect(record.history_len).toBe(0);
    }
    expect(
      readFileSync(join(fixture.home, ".fx", "history.jsonl"), "utf8"),
    ).toContain("/quit");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

    await waitForTerminalHostExit(fixture.home);
    expect(existsSync(terminalTransportPaths(fixture.home).socket)).toBe(false);
  },
  45_000,
);

test.skipIf(!tmuxAvailable())(
  "invalid and queue-full direct admission preserve draft owners while startup is slow",
  async () => {
    const fixture = createFixture("fx-tui-terminal-queue-");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway, {
      FX_TERMINAL_TEST_CLIENT_REQUEST_DELAY_MS: "15000",
    });

    await active.sendText("!");
    let pane = await active.waitForText("Direct terminal was not started", TIMEOUT);
    expect(pane).toContain("!");
    await active.sendKeys("C-u");

    for (let index = 0; index < 32; index++) {
      await active.sendText(
        `!printf QUEUED_${index}; ${holdUntilCleanup(fixture.root)}`,
      );
      await Bun.sleep(100);
    }
    await active.waitForText("Starting: printf QUEUED_31", TIMEOUT);
    await active.sendText(`/image ${fixture.imagePath}`);
    await active.waitForText("[Image 1]", TIMEOUT);
    await active.sendKeys("Home");
    await active.pasteText("!QUEUE_FULL_DRAFT #" + "q".repeat(1_050));
    await active.sendKeys("Enter");
    pane = await active.waitForText("QueueFull", TIMEOUT);
    expect(pane).toContain("[Pasted text #1, 1 line]");
    expect(pane).toContain("[Image 1]");

    await active.resizeWindow(68, 12);
    await active.sendKeys("C-x");
    await active.waitForText("Agents & processes", TIMEOUT);
    await active.sendKeys("Escape");
    const compactManager = await active.waitForText(
      "Agents & processes",
      TIMEOUT,
    );
    expect(compactManager).toContain("ctrl-x close");
    expect(compactManager).not.toContain("r archives");
    await active.sendKeys("C-x");
    pane = await active.waitForText("[Pasted text #1, 1 line]", TIMEOUT);
    expect(pane).toContain("[Image 1]");
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(fixture.tracePath, "utf8")).not.toContain(
      "draft images dropped count=1 reason=direct_terminal",
    );
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  45_000,
);

test.skipIf(!tmuxAvailable() || loginProfileName === null)(
  "failed direct start stays responsive and publishes one structured final notice",
  async () => {
    const fixture = createFixture("fx-tui-terminal-failed-start-");
    const profileStartedPath = join(fixture.root, "profile-started");
    const profilePidPath = join(fixture.root, "profile.pid");
    writeFileSync(
      join(fixture.home, loginProfileName!),
      `printf started > ${JSON.stringify(profileStartedPath)}\n` +
        `printf '%s' "$$" > ${JSON.stringify(profilePidPath)}\n` +
        "sleep 4\n" +
        "exit 41\n",
    );
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    const commandRanPath = join(fixture.root, "command-ran");
    const command = `: > ${JSON.stringify(commandRanPath)}`;

    await active.sendText(`!${command}`);
    await active.sendKeys("Enter");
    await active.waitForText(`Starting: ${command}`, TIMEOUT);
    await waitForTrace(profileStartedPath, "started");

    await active.resizeWindow(72, 12);
    await active.sendLiteralText("DIRECT_FAILURE_DRAFT");
    await active.sendKeys("C-x");
    let manager = await active.waitForText("Agents & processes", TIMEOUT);
    await active.sendKeys("Escape");
    manager = await active.waitForText("Agents & processes", TIMEOUT);
    expect(manager).toContain("r archives");
    await active.sendKeys("C-x");
    await active.waitForText("DIRECT_FAILURE_DRAFT", TIMEOUT);
    expect(await active.captureFullScrollback()).not.toContain(
      `Failed startup_failed: ${command}`,
    );
    await active.resizeWindow(120, 30);

    await active.waitForText(`Failed startup_failed: ${command}`, TIMEOUT).catch(
      async (error) => {
        const diagnostics = `${error}\nSCROLLBACK\n${await active.captureFullScrollback()}\nTRACE\n${readFileSync(fixture.tracePath, "utf8")}`;
        throw new Error(diagnostics);
      },
    );
    await Bun.sleep(300);
    const scrollback = await active.captureFullScrollback();
    expect(countOccurrences(scrollback, `Starting: ${command}`)).toBe(1);
    expect(
      countOccurrences(scrollback, `Failed startup_failed: ${command}`),
    ).toBe(1);
    expect(
      scrollback.split("\n").filter((line) =>
        line.includes("Running ") && line.includes(command)
      ),
    ).toHaveLength(0);
    expect(existsSync(commandRanPath)).toBe(false);
    expect(gateway.requests).toHaveLength(0);

    const trace = readFileSync(fixture.tracePath, "utf8");
    expect(trace).not.toContain("[gateway]");
    expect(trace).not.toContain("[worker]");
    expect(trace).not.toContain("[agent]");
    for (const record of sessionRecords(fixture.home)) {
      expect(record.history_len).toBe(0);
    }
    expect(existsSync(join(fixture.home, ".fx", "history.jsonl"))).toBe(false);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

    const profilePid = Number(readFileSync(profilePidPath, "utf8"));
    expect(Number.isSafeInteger(profilePid)).toBe(true);
    expect(() => process.kill(profilePid, 0)).toThrow();

    await active.kill();
    sessions.splice(sessions.indexOf(active), 1);
    await waitForTerminalHostExit(fixture.home);
    expect(
      existsSync(join(fixture.home, ".fx", "terminal-host", "host.json")),
    ).toBe(false);

    gateway.stop();
    gateways.splice(gateways.indexOf(gateway), 1);
    rmSync(fixture.root, { recursive: true, force: true });
    roots.splice(roots.indexOf(fixture.root), 1);
    expect(existsSync(fixture.root)).toBe(false);
  },
  45_000,
);
