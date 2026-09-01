import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { FX_BIN, REPO_ROOT } from "../../evals/eval-helpers";
import { analyzeRun } from "./analyzer";
import {
  attachFrameEvidence,
  runtimeEvidenceDefaults,
  waitForStableProbe,
  writeRuntimeEvidence,
} from "./evidence";
import { writeReport } from "./report";
import type {
  RenderLabFailure,
  RenderLabFrame,
  RenderLabFrameManifest,
  RenderLabManifest,
} from "./types";

export const NATIVE_GATE_ENV = "FX_RENDER_LAB_NATIVE";
export const NATIVE_COMMAND_K_ENV = "FX_RENDER_LAB_NATIVE_COMMAND_K";
export const NATIVE_CLIPBOARD_ENV = "FX_RENDER_LAB_NATIVE_ALLOW_CLIPBOARD";

type NativeAdapterName = "terminal-app" | "ghostty" | "warp";
type NativeCapture = "terminal-contents" | "clipboard";

type NativeScenario = {
  name: string;
  adapter: NativeAdapterName;
  appName: string;
  appPath: string;
  termProgram: string;
  capture: NativeCapture;
  commandK: boolean;
  requiresClipboard: boolean;
  notes: string[];
};

type Fixture = {
  root: string;
  home: string;
  zdotdir: string;
  work: string;
  histfile: string;
};

type NativeContext = {
  fixture: Fixture;
  manifest: RenderLabManifest;
  binarySha256: string;
};

type NativeController = {
  start(): Promise<void>;
  sendText(text: string): Promise<void>;
  resize(cols: number, rows: number): Promise<void>;
  triggerCommandK(): Promise<void>;
  captureText(): string;
  close(): Promise<void>;
  captureSource: string;
  width: number;
  height: number;
};

const PROMPT_TEXT = "FX_RENDER_LAB%";
const TRACE_SCOPES =
  "render,paint,resize,scroll,footer.clean,input";

const NATIVE_SCENARIOS: NativeScenario[] = [
  {
    name: "native-ghostty-relaunch",
    adapter: "ghostty",
    appName: "Ghostty",
    appPath: "/Applications/Ghostty.app",
    termProgram: "Ghostty",
    capture: "clipboard",
    commandK: false,
    requiresClipboard: true,
    notes: [
      "Launches a real Ghostty window and captures selected terminal text through the macOS clipboard.",
      "Use this as platform evidence only when the run artifact contains native frames from Ghostty.",
    ],
  },
  {
    name: "native-terminal-app-relaunch",
    adapter: "terminal-app",
    appName: "Terminal",
    appPath: "/System/Applications/Utilities/Terminal.app",
    termProgram: "Apple_Terminal",
    capture: "terminal-contents",
    commandK: false,
    requiresClipboard: false,
    notes: [
      "Uses Terminal.app AppleScript contents for native scrollback capture.",
      "This is the least invasive native adapter because it does not need clipboard capture.",
    ],
  },
  {
    name: "native-terminal-app-command-k",
    adapter: "terminal-app",
    appName: "Terminal",
    appPath: "/System/Applications/Utilities/Terminal.app",
    termProgram: "Apple_Terminal",
    capture: "terminal-contents",
    commandK: true,
    requiresClipboard: false,
    notes: [
      "Triggers the real macOS Terminal Command-K UI action through System Events.",
      "Requires the additional FX_RENDER_LAB_NATIVE_COMMAND_K=1 gate because it clears scrollback.",
    ],
  },
  {
    name: "native-warp-relaunch",
    adapter: "warp",
    appName: "Warp",
    appPath: "/Applications/Warp.app",
    termProgram: "WarpTerminal",
    capture: "clipboard",
    commandK: false,
    requiresClipboard: true,
    notes: [
      "Launches Warp and captures selected terminal text through the macOS clipboard.",
      "Warp private OSC/DCS bytes are treated as adapter metadata only, not visible-grid proof.",
    ],
  },
];

export function isNativeScenario(name: string): boolean {
  return NATIVE_SCENARIOS.some((scenario) => scenario.name === name);
}

export function nativeScenarioNames(): string[] {
  return NATIVE_SCENARIOS.map((scenario) => scenario.name);
}

export function nativeScenarioHelpLines(): string[] {
  return [
    "native scenarios, all opt-in:",
    ...NATIVE_SCENARIOS.map((scenario) => {
      const gates = [NATIVE_GATE_ENV];
      if (scenario.commandK) gates.push(NATIVE_COMMAND_K_ENV);
      if (scenario.requiresClipboard) gates.push(NATIVE_CLIPBOARD_ENV);
      return `  ${scenario.name} (${scenario.appName}, gates: ${gates.map((gate) => `${gate}=1`).join(" ")})`;
    }),
  ];
}

export async function runNativeRenderLab(
  scenarioName: string,
  outRoot: string,
  runNumber: number,
): Promise<RenderLabManifest> {
  const scenario = NATIVE_SCENARIOS.find((candidate) => candidate.name === scenarioName);
  if (!scenario) throw new Error(`unknown native render-lab scenario: ${scenarioName}`);
  assertNativeGates(scenario);
  preflightNative(scenario);

  const startedAt = new Date();
  const runId = `${scenario.name}-${timestampForPath(startedAt)}-${runNumber}-${randomBytes(3).toString("hex")}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const shellMarkers = scenario.commandK
    ? [`SHELL_B_BEFORE_CLEAR_${runId}`, `SHELL_B_AFTER_CLEAR_${runId}`]
    : [
        `SHELL_B_BEFORE_FIRST_${runId}`,
        `SHELL_B_BETWEEN_LAUNCHES_${runId}`,
        `SHELL_B_BEFORE_THIRD_${runId}`,
      ];
  const manifest: RenderLabManifest = {
    version: 1,
    scenario: scenario.name,
    runId,
    startedAt: startedAt.toISOString(),
    completedAt: null,
    repoRoot: REPO_ROOT,
    artifactDir,
    binaryPath: FX_BIN,
    binarySha256,
    traceLogPath: join(artifactDir, "trace.log"),
    tapePath: join(artifactDir, "render.fxtape"),
    finalGridPath: join(artifactDir, "final-grid.txt"),
    replaySummaryPath: join(artifactDir, "replay-summary.json"),
    runtimeEvidencePath: join(artifactDir, "runtime-evidence.json"),
    reportPath: join(artifactDir, "report.html"),
    failurePath: join(artifactDir, "failure.md"),
    finalFrameIndex: null,
    evidence: runtimeEvidenceDefaults(),
    markers: {
      shell: shellMarkers,
      clearedShell: scenario.commandK ? [shellMarkers[0]!] : [],
      submitted: scenario.commandK ? ["permission_mode", "● Version:"] : ["permission_mode", "● Version:", "/help"],
    },
    native: {
      adapter: scenario.adapter,
      appName: scenario.appName,
      termProgram: scenario.termProgram,
      capture: scenario.capture,
      commandK: scenario.commandK,
      notes: scenario.notes,
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest, scenario);

  const fixture = createFixture(runId);
  const context = { fixture, manifest, binarySha256 };
  let controller: NativeController | null = null;
  try {
    controller = createController(scenario, fixture, manifest, 120, 40);
    await controller.start();
    await waitForText(controller, PROMPT_TEXT, 20_000);
    await capture(context, controller, "native-shell-started");

    if (scenario.commandK) {
      await runCommandKScenario(context, controller);
    } else {
      await runNativeRelaunchScenario(context, controller);
    }

    await controller.sendText("exit");
    await sleep(500);
    await controller.close();
    controller = null;

    await writeReplaySummary(manifest);
    writeRuntimeEvidence(manifest);
    const analysis = analyzeRun(manifest);
    manifest.failures = analysis.failures;
    manifest.completedAt = new Date().toISOString();
    writeManifest(manifest);
    writeFailureFile(manifest);
    writeReport(manifest);
    return manifest;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const failure: RenderLabFailure = {
      invariant: "native-scenario-error",
      frameIndex: manifest.frames.at(-1)?.index ?? 0,
      event: manifest.frames.at(-1)?.event ?? "startup",
      message,
    };
    manifest.failures = [...manifest.failures, failure];
    manifest.completedAt = new Date().toISOString();
    writeManifest(manifest);
    writeFailureFile(manifest);
    try {
      writeReport(manifest);
    } catch {}
    throw error;
  } finally {
    if (controller) await controller.close();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function runNativeRelaunchScenario(
  context: NativeContext,
  controller: NativeController,
): Promise<void> {
  await runShellCommand(context, controller, "pwd", context.fixture.work, "native-shell-pwd");
  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' "$SHELL_B_BEFORE_FIRST"`,
    context.manifest.markers.shell[0]!,
    "native-shell-before-first",
  );
  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' ${shQuote(longLine(context.manifest.runId, "first"))}`,
    "first-11",
    "native-shell-long-line-before-first",
  );

  await launchFx(context, controller, "native-first");
  await submitSlashCommand(context, controller, "/status", "permission_mode", "native-first-status-visible");
  await quitFx(context, controller, "native-first");

  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' "$SHELL_B_BETWEEN_LAUNCHES"`,
    context.manifest.markers.shell[1]!,
    "native-shell-between-launches",
  );

  await launchFx(context, controller, "native-second");
  await submitSlashCommand(context, controller, "/version", "● Version:", "native-second-version-visible");
  await resize(context, controller, 96, 32, "native-second-resize-medium");
  await resize(context, controller, 132, 42, "native-second-resize-wide");
  await resize(context, controller, 120, 40, "native-second-resize-restored");
  await quitFx(context, controller, "native-second");

  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' "$SHELL_B_BEFORE_THIRD"`,
    context.manifest.markers.shell[2]!,
    "native-shell-before-third",
  );
  await launchFx(context, controller, "native-third");
  await submitSlashCommand(context, controller, "/help", "/version", "native-third-help-visible");
  const finalFrame = await capture(context, controller, "native-final-third-launch-state");
  context.manifest.finalFrameIndex = finalFrame.index;
  await quitFx(context, controller, "native-third-cleanup");
}

async function runCommandKScenario(context: NativeContext, controller: NativeController): Promise<void> {
  await runShellCommand(context, controller, "pwd", context.fixture.work, "native-command-k-shell-pwd");
  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' "$SHELL_B_BEFORE_CLEAR"`,
    context.manifest.markers.shell[0]!,
    "native-command-k-before-clear-marker",
  );
  await launchFx(context, controller, "native-command-k-before-clear");
  await submitSlashCommand(
    context,
    controller,
    "/status",
    "permission_mode",
    "native-command-k-status-visible",
  );
  await quitFx(context, controller, "native-command-k-before-clear");

  await controller.triggerCommandK();
  await sleep(600);
  await capture(context, controller, "native-command-k-triggered");

  await runShellCommand(
    context,
    controller,
    `printf '%s\\n' "$SHELL_B_AFTER_CLEAR"`,
    context.manifest.markers.shell[1]!,
    "native-command-k-after-clear-marker",
  );
  await launchFx(context, controller, "native-command-k-after-clear");
  await submitSlashCommand(context, controller, "/version", "● Version:", "native-command-k-version-visible");
  const finalFrame = await capture(context, controller, "native-command-k-final-state");
  context.manifest.finalFrameIndex = finalFrame.index;
  await quitFx(context, controller, "native-command-k-cleanup");
}

async function launchFx(
  context: NativeContext,
  controller: NativeController,
  label: string,
): Promise<void> {
  await controller.sendText(
    `FX_RECORD=${shQuote(context.manifest.tapePath)} FX_RECORD_INPUT=1 ${shQuote(FX_BIN)}`,
  );
  await capture(context, controller, `${label}-fx-launch-requested`);
  await waitForText(controller, "Run /help for commands", 30_000);
  await capture(context, controller, `${label}-fx-prompt-visible`);
}

async function submitSlashCommand(
  context: NativeContext,
  controller: NativeController,
  command: string,
  expected: string,
  event: string,
): Promise<void> {
  await controller.sendText(command);
  await waitForText(controller, expected, 15_000);
  await capture(context, controller, event);
}

async function quitFx(context: NativeContext, controller: NativeController, label: string): Promise<void> {
  await controller.sendText("/quit");
  await capture(context, controller, `${label}-fx-quit-requested`);
  await waitForText(controller, PROMPT_TEXT, 20_000);
  await capture(context, controller, `${label}-post-quit-shell-prompt`);
}

async function runShellCommand(
  context: NativeContext,
  controller: NativeController,
  command: string,
  expected: string,
  event: string,
): Promise<void> {
  await controller.sendText(command);
  await waitForText(controller, expected, 15_000);
  await capture(context, controller, event);
}

async function resize(
  context: NativeContext,
  controller: NativeController,
  cols: number,
  rows: number,
  event: string,
): Promise<void> {
  await controller.resize(cols, rows);
  await sleep(700);
  await capture(context, controller, event);
}

async function capture(
  context: NativeContext,
  controller: NativeController,
  event: string,
): Promise<RenderLabFrame> {
  const probe = await waitForStableProbe(() => controller.captureText());
  const frame = attachFrameEvidence(
    captureNativeFrame(
      context.manifest.frames.length + 1,
      event,
      context.manifest.binaryPath,
      context.binarySha256,
      context.manifest.traceLogPath,
      controller,
    ),
    controller.captureSource,
    probe,
  );
  writeFrame(context.manifest, frame);
  writeManifest(context.manifest);
  return frame;
}

function captureNativeFrame(
  index: number,
  event: string,
  binaryPath: string,
  binarySha256: string,
  traceLogPath: string,
  controller: NativeController,
): RenderLabFrame {
  const text = controller.captureText();
  const lines = normalizeLines(text);
  const grid = lines.slice(-controller.height);
  while (grid.length < controller.height) grid.unshift("");
  return {
    index,
    event,
    timestampMs: Date.now(),
    width: controller.width,
    height: controller.height,
    binaryPath,
    binarySha256,
    grid,
    escapes: "",
    scrollback: text,
    cursor: null,
    traceTail: traceTail(traceLogPath),
  };
}

function createController(
  scenario: NativeScenario,
  fixture: Fixture,
  manifest: RenderLabManifest,
  width: number,
  height: number,
): NativeController {
  if (scenario.adapter === "terminal-app") {
    return new TerminalAppController(scenario, fixture, manifest, width, height);
  }
  return new ClipboardUiController(scenario, fixture, manifest, width, height);
}

class TerminalAppController implements NativeController {
  width: number;
  height: number;
  readonly captureSource = "terminal-app-contents";
  private closed = false;
  private windowId: number | null = null;

  constructor(
    private readonly scenario: NativeScenario,
    private readonly fixture: Fixture,
    private readonly manifest: RenderLabManifest,
    width: number,
    height: number,
  ) {
    this.width = width;
    this.height = height;
  }

  async start(): Promise<void> {
    const command = startShellCommand(this.fixture, this.manifest, this.scenario);
    const rawWindowId = osascript(`
tell application "Terminal"
  activate
  set labTab to do script ""
  set number of columns of labTab to ${this.width}
  set number of rows of labTab to ${this.height}
  return id of front window
end tell
`).trim();
    const windowId = Number.parseInt(rawWindowId, 10);
    if (!Number.isFinite(windowId)) throw new Error(`invalid Terminal.app window id: ${rawWindowId}`);
    this.windowId = windowId;
    await sleep(800);
    await this.sendText(command);
    await sleep(1_000);
  }

  async sendText(text: string): Promise<void> {
    osascript(`${terminalWindowPrelude(this.requireWindowId())}
set labCommand to ${osaQuote(text)}
tell application "Terminal"
  do script labCommand in selected tab of targetWindow
end tell
`);
    await sleep(180);
  }

  async resize(cols: number, rows: number): Promise<void> {
    this.width = cols;
    this.height = rows;
    osascript(`${terminalWindowPrelude(this.requireWindowId())}
tell application "Terminal"
  set number of columns of selected tab of targetWindow to ${cols}
  set number of rows of selected tab of targetWindow to ${rows}
end tell
`);
    await sleep(400);
  }

  async triggerCommandK(): Promise<void> {
    osascript(`${terminalWindowPrelude(this.requireWindowId())}
tell application "System Events"
  keystroke "k" using command down
end tell
`);
    await sleep(400);
  }

  captureText(): string {
    return osascript(`${terminalWindowPrelude(this.requireWindowId())}
tell application "Terminal"
  set targetProperties to properties of selected tab of targetWindow
  return contents of targetProperties
end tell
`);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try {
      osascript(`${terminalWindowPrelude(this.requireWindowId())}
tell application "Terminal"
  close targetWindow
end tell
`);
    } catch {}
  }

  private requireWindowId(): number {
    if (this.windowId == null) throw new Error("Terminal.app controller has not started");
    return this.windowId;
  }
}

class ClipboardUiController implements NativeController {
  width: number;
  height: number;
  readonly captureSource = "native-clipboard-selection";
  private closed = false;

  constructor(
    private readonly scenario: NativeScenario,
    private readonly fixture: Fixture,
    private readonly manifest: RenderLabManifest,
    width: number,
    height: number,
  ) {
    this.width = width;
    this.height = height;
  }

  async start(): Promise<void> {
    const command = startShellCommand(this.fixture, this.manifest, this.scenario);
    execFileSync("open", ["-na", this.scenario.appName], { stdio: ["ignore", "ignore", "pipe"] });
    await sleep(1_500);
    this.focus();
    pasteIntoFrontApp(this.scenario.appName, command);
    await sleep(1_000);
  }

  async sendText(text: string): Promise<void> {
    this.focus();
    pasteIntoFrontApp(this.scenario.appName, text);
    await sleep(220);
  }

  async resize(cols: number, rows: number): Promise<void> {
    this.width = cols;
    this.height = rows;
    const pixelWidth = Math.max(640, cols * 8 + 40);
    const pixelHeight = Math.max(420, rows * 18 + 80);
    this.focus();
    osascript(`
tell application "System Events"
  tell process ${osaQuote(this.scenario.appName)}
    set size of front window to {${pixelWidth}, ${pixelHeight}}
  end tell
end tell
`);
    await sleep(500);
  }

  async triggerCommandK(): Promise<void> {
    this.focus();
    osascript(`
tell application "System Events"
  tell process ${osaQuote(this.scenario.appName)}
    keystroke "k" using command down
  end tell
end tell
`);
    await sleep(500);
  }

  captureText(): string {
    this.focus();
    const saved = readClipboard();
    try {
      osascript(`
tell application "System Events"
  tell process ${osaQuote(this.scenario.appName)}
    keystroke "a" using command down
    delay 0.15
    keystroke "c" using command down
    delay 0.25
    key code 53
  end tell
end tell
`);
      return readClipboard();
    } finally {
      writeClipboard(saved);
    }
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try {
      this.focus();
      pasteIntoFrontApp(this.scenario.appName, "exit");
      await sleep(400);
    } catch {}
  }

  private focus(): void {
    osascript(`tell application ${osaQuote(this.scenario.appName)} to activate`);
  }
}

async function waitForText(
  controller: NativeController,
  expected: string,
  timeoutMs: number,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const text = controller.captureText();
    if (text.includes(expected)) return text;
    await sleep(350);
  }
  throw new Error(`timed out waiting for native terminal text: ${expected}`);
}

function longLine(runId: string, label: string): string {
  return Array.from({ length: 12 }, (_, index) => `shell-wrap-${runId}-${label}-${index}`).join("-");
}

function assertNativeGates(scenario: NativeScenario): void {
  if (process.env[NATIVE_GATE_ENV] !== "1") {
    throw new Error(
      `${scenario.name} is a native terminal render-lab scenario. Set ${NATIVE_GATE_ENV}=1 to run it. Default CI must not run native terminal scenarios.`,
    );
  }
  if (scenario.commandK && process.env[NATIVE_COMMAND_K_ENV] !== "1") {
    throw new Error(
      `${scenario.name} triggers the real Command-K clear-scrollback action. Set ${NATIVE_COMMAND_K_ENV}=1 as an explicit second gate.`,
    );
  }
  if (scenario.requiresClipboard && process.env[NATIVE_CLIPBOARD_ENV] !== "1") {
    throw new Error(
      `${scenario.name} captures ${scenario.appName} through the macOS clipboard. Set ${NATIVE_CLIPBOARD_ENV}=1 to allow clipboard save and restore.`,
    );
  }
}

function preflightNative(scenario: NativeScenario): void {
  if (process.platform !== "darwin") {
    throw new Error(`${scenario.name} requires macOS native terminal automation`);
  }
  if (!existsSync(FX_BIN)) {
    throw new Error(`fx binary not found at ${FX_BIN}. Run zig build first.`);
  }
  const stat = statSync(FX_BIN);
  if (!stat.isFile() || (stat.mode & 0o111) === 0) {
    throw new Error(`fx binary is not executable at ${FX_BIN}`);
  }
  if (!existsSync(scenario.appPath)) {
    throw new Error(`${scenario.appName} app not found at ${scenario.appPath}`);
  }
  osascript("return \"ok\"");
}

function startShellCommand(
  fixture: Fixture,
  manifest: RenderLabManifest,
  scenario: NativeScenario,
): string {
  const markerEnv = scenario.commandK
    ? [
        `SHELL_B_BEFORE_CLEAR=${shQuote(manifest.markers.shell[0]!)}`,
        `SHELL_B_AFTER_CLEAR=${shQuote(manifest.markers.shell[1]!)}`,
      ]
    : [
        `SHELL_B_BEFORE_FIRST=${shQuote(manifest.markers.shell[0]!)}`,
        `SHELL_B_BETWEEN_LAUNCHES=${shQuote(manifest.markers.shell[1]!)}`,
        `SHELL_B_BEFORE_THIRD=${shQuote(manifest.markers.shell[2]!)}`,
      ];
  const env = [
    "-u",
    "AI_GATEWAY_API_KEY",
    "-u",
    "VERCEL_OIDC_TOKEN",
    `HOME=${shQuote(fixture.home)}`,
    `ZDOTDIR=${shQuote(fixture.zdotdir)}`,
    `HISTFILE=${shQuote(fixture.histfile)}`,
    `SHELL=${shQuote(zshPath())}`,
    `TERM_PROGRAM=${shQuote(scenario.termProgram)}`,
    "FX_E2E_DISABLE_SESSION_TITLE_GENERATION=1",
    `FX_TRACE_LOG=${shQuote(manifest.traceLogPath)}`,
    `FX_TRACE_SCOPES=${shQuote(TRACE_SCOPES)}`,
    ...markerEnv,
    shQuote(zshPath()),
    "-i",
  ].join(" ");
  return `cd ${shQuote(fixture.work)} && exec env ${env}`;
}

function createFixture(runId: string): Fixture {
  const root = realpathSync(mkdtempSync(join(shortTempBase(), "fxrl-native-")));
  const fixture = {
    root,
    home: join(root, "h"),
    zdotdir: join(root, "z"),
    work: join(root, "w"),
    histfile: join(root, "hist"),
  };
  mkdirSync(fixture.home, { recursive: true });
  mkdirSync(fixture.zdotdir, { recursive: true });
  mkdirSync(fixture.work, { recursive: true });
  writeFileSync(join(fixture.work, "run-id.txt"), `${runId}\n`);
  writeFileSync(
    join(fixture.zdotdir, ".zshrc"),
    ["PROMPT='FX_RENDER_LAB%% '", "RPROMPT=''", "setopt NO_BEEP", ""].join("\n"),
  );
  return fixture;
}

function writeFrame(manifest: RenderLabManifest, frame: RenderLabFrame): void {
  const name = pad(frame.index);
  const jsonPath = join("replay", "frames", `${name}.json`);
  const gridPath = join("replay", "frames", `${name}.grid.txt`);
  writeFileSync(join(manifest.artifactDir, jsonPath), `${JSON.stringify(frame, null, 2)}\n`);
  writeFileSync(join(manifest.artifactDir, gridPath), `${frame.grid.join("\n")}\n`);
  const entry: RenderLabFrameManifest = {
    index: frame.index,
    event: frame.event,
    timestampMs: frame.timestampMs,
    width: frame.width,
    height: frame.height,
    gridPath,
    jsonPath,
  };
  manifest.frames.push(entry);
  writeReplayManifest(manifest);
}

async function writeReplaySummary(manifest: RenderLabManifest): Promise<void> {
  try {
    const output = execFileSync(
      FX_BIN,
      ["replay", manifest.tapePath, "--json", "--golden", manifest.finalGridPath],
      { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    const jsonLine = output.split(/\r?\n/).find((line) => line.trim().startsWith("{"));
    if (jsonLine) {
      writeFileSync(manifest.replaySummaryPath, `${jsonLine}\n`);
      return;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeFileSync(manifest.replaySummaryPath, `${JSON.stringify({ error: message }, null, 2)}\n`);
  }

  const finalFramePath = manifest.frames.find((frame) => frame.index === manifest.finalFrameIndex)?.gridPath;
  if (finalFramePath && !existsSync(manifest.finalGridPath)) {
    writeFileSync(manifest.finalGridPath, readFileSync(join(manifest.artifactDir, finalFramePath)));
  }
}

function writeManifest(manifest: RenderLabManifest): void {
  writeFileSync(join(manifest.artifactDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}

function writeReplayManifest(manifest: RenderLabManifest): void {
  writeFileSync(
    join(manifest.artifactDir, "replay", "manifest.json"),
    `${JSON.stringify({ frames: manifest.frames }, null, 2)}\n`,
  );
}

function writeFailureFile(manifest: RenderLabManifest): void {
  if (manifest.failures.length === 0) {
    writeFileSync(manifest.failurePath, "# Render Lab Failure Notes\n\nNo analyzer failures.\n");
    return;
  }
  const lines = ["# Render Lab Failure Notes", ""];
  for (const failure of manifest.failures) {
    lines.push(
      `- ${failure.invariant} at frame ${failure.frameIndex} (${failure.event}): ${failure.message}`,
    );
  }
  writeFileSync(manifest.failurePath, `${lines.join("\n")}\n`);
}

function writeReproScript(manifest: RenderLabManifest, scenario: NativeScenario): void {
  const gates = [`${NATIVE_GATE_ENV}=1`];
  if (scenario.commandK) gates.push(`${NATIVE_COMMAND_K_ENV}=1`);
  if (scenario.requiresClipboard) gates.push(`${NATIVE_CLIPBOARD_ENV}=1`);
  const script = [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    `cd ${shQuote(join(REPO_ROOT, "tests", "e2e"))}`,
    `${gates.join(" ")} ${shQuote(bunPath())} run render-lab -- --scenario ${manifest.scenario} --runs 1 --out ${shQuote(dirname(manifest.artifactDir))}`,
    "",
  ].join("\n");
  writeFileSync(join(manifest.artifactDir, "repro.sh"), script, { mode: 0o755 });
}

function normalizeLines(text: string): string[] {
  if (text.length === 0) return [];
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n$/, "").split("\n");
}

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function traceTail(path: string): string[] {
  try {
    return readFileSync(path, "utf8").split(/\r?\n/).slice(-80);
  } catch {
    return [];
  }
}

function pad(value: number): string {
  return String(value).padStart(4, "0");
}

let cachedZshPath: string | null = null;
function zshPath(): string {
  if (cachedZshPath) return cachedZshPath;
  if (existsSync("/bin/zsh")) {
    cachedZshPath = "/bin/zsh";
    return cachedZshPath;
  }
  const resolved = execFileSync("sh", ["-c", "command -v zsh"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  if (!resolved) throw new Error("zsh not found");
  cachedZshPath = resolved;
  return cachedZshPath;
}

function bunPath(): string {
  try {
    return execFileSync("sh", ["-c", "command -v bun"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "bun";
  }
}

function shortTempBase(): string {
  for (const candidate of ["/private/tmp", "/tmp"]) {
    try {
      const stat = statSync(candidate);
      if (stat.isDirectory()) return realpathSync(candidate);
    } catch {}
  }
  throw new Error("no short temp directory available");
}

function timestampForPath(date: Date): string {
  return date.toISOString().replaceAll(":", "").replaceAll(".", "-");
}

function osascript(script: string): string {
  return execFileSync("osascript", ["-e", script], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function terminalWindowPrelude(windowId: number): string {
  return `
set labWindowId to ${windowId}
set targetWindow to missing value
tell application "Terminal"
  repeat with w in windows
    if (id of w) is labWindowId then
      set targetWindow to w
      set selected tab of w to tab 1 of w
      set index of w to 1
      exit repeat
    end if
  end repeat
  if targetWindow is missing value then error "render-lab Terminal window not found"
  activate
end tell`;
}

function pasteIntoFrontApp(appName: string, text: string): void {
  const saved = readClipboard();
  try {
    writeClipboard(text);
    osascript(`
tell application ${osaQuote(appName)} to activate
tell application "System Events"
  tell process ${osaQuote(appName)}
    keystroke "v" using command down
    key code 36
  end tell
end tell
`);
  } finally {
    writeClipboard(saved);
  }
}

function readClipboard(): string {
  return execFileSync("pbpaste", [], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
}

function writeClipboard(value: string): void {
  execFileSync("pbcopy", [], { input: value, encoding: "utf8", stdio: ["pipe", "ignore", "ignore"] });
}

function osaQuote(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function shQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
