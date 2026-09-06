/**
 * Deterministic UI observer runner.
 *
 * This is an inspection tool, not a golden test suite. It launches the
 * freshly built fx binary in tmux, arms one observer checkpoint, releases one
 * fixture transition, and saves terminal plus replay artifacts for review.
 */
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { readTapeFrames } from "./render-lab/tape";

const TIMEOUT_MS = 20_000;

type ScenarioName =
  | "idle-composer"
  | "streaming-assistant"
  | "markdown"
  | "file-approval"
  | "question"
  | "resize"
  | "thinking-shimmer"
  | "thinking-running"
  | "thinking-final"
  | "thinking-failed"
  | "thinking-none"
  | "tool-denied"
  | "tool-cancelled";

type ArmKind = "normal" | "alternate_screen";
type ActivityKind = "none" | "turn_thinking" | "tool_slot";

type ScenarioContext = {
  workspace: string;
  artifactDir: string;
  session: TmuxSession;
  gateway: ReturnType<typeof startFakeGateway>;
  checkpoint: string;
  armKind: ArmKind;
  activityKind?: ActivityKind;
  streamActive?: boolean;
  completedAssistantPresentationTail?: boolean;
  contains?: string;
  trigger(): Promise<void>;
  expected(record: Record<string, unknown>): boolean;
};

type Deferred = {
  promise: Promise<void>;
  release(): void;
};

function deferred(): Deferred {
  let resolve: (() => void) | undefined;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return {
    promise,
    release() {
      resolve?.();
    },
  };
}

function parseArgs(): {
  scenario: ScenarioName | null;
  keep: boolean;
  hold: boolean;
  list: boolean;
  size: { width: number; height: number };
} {
  const args = process.argv.slice(2);
  let scenario: ScenarioName | null = null;
  let keep = false;
  let hold = false;
  let list = false;
  let size = { width: 120, height: 40 };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--scenario") {
      const value = args[++index];
      if (!isScenarioName(value)) throw new Error(`unknown scenario: ${value ?? ""}`);
      scenario = value;
      continue;
    }
    if (arg === "--keep") {
      keep = true;
      continue;
    }
    if (arg === "--hold") {
      hold = true;
      keep = true;
      continue;
    }
    if (arg === "--list") {
      list = true;
      continue;
    }
    if (arg === "--size") {
      const value = args[++index] ?? "";
      const match = /^(\d+)x(\d+)$/.exec(value);
      if (!match) throw new Error(`invalid size: ${value}`);
      size = { width: Number(match[1]), height: Number(match[2]) };
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  return { scenario, keep, hold, list, size };
}

function isScenarioName(value: string | undefined): value is ScenarioName {
  return value === "idle-composer" ||
    value === "streaming-assistant" ||
    value === "markdown" ||
    value === "file-approval" ||
    value === "question" ||
    value === "resize" ||
    value === "thinking-shimmer" ||
    value === "thinking-running" ||
    value === "thinking-final" ||
    value === "thinking-failed" ||
    value === "thinking-none" ||
    value === "tool-denied" ||
    value === "tool-cancelled";
}

function createFixtureRoot(autoPermissions = false) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-ui-observer-fixture-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      sandbox: "none",
      permission_mode: autoPermissions ? "auto" : "ask",
      permission: {},
    }),
  );
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function createArtifactDir(keep: boolean): string {
  const configured = process.env.FX_UI_OBSERVER_ARTIFACT_DIR;
  if (configured) {
    mkdirSync(configured, { recursive: true });
    return realpathSync(configured);
  }
  const root = mkdtempSync(join(tmpdir(), "fx-ui-observer-"));
  if (keep) return realpathSync(root);
  return root;
}

function gatewayEnv(
  fixture: ReturnType<typeof createFixtureRoot>,
  gateway: ReturnType<typeof startFakeGateway>,
  artifactDir: string,
) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "ui-observer-local",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_UI_OBSERVE_DIR: artifactDir,
    FX_RECORD: join(artifactDir, "session.fxtp"),
    NO_COLOR: "1",
  };
}

async function waitFor(
  predicate: () => boolean,
  description: string,
  timeoutMs = TIMEOUT_MS,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${description}`);
}

function frameRecords(artifactDir: string): Array<Record<string, unknown>> {
  const path = join(artifactDir, "frames.jsonl");
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function lastSequence(artifactDir: string): number {
  const records = frameRecords(artifactDir);
  const last = records.at(-1);
  if (!last || typeof last.sequence !== "number") {
    throw new Error("observer did not produce a pre-checkpoint frame");
  }
  return last.sequence;
}

function writeArm(
  artifactDir: string,
  scenario: ScenarioName,
  checkpoint: string,
  kind: ArmKind,
  sequenceFloor: number,
  activityKind?: ActivityKind,
  streamActive?: boolean,
  completedAssistantPresentationTail?: boolean,
  contains?: string,
) {
  writeFileSync(
    join(artifactDir, "arm"),
    [
      `kind=${kind}`,
      `scenario=${scenario}`,
      `checkpoint=${checkpoint}`,
      `sequence_floor=${sequenceFloor}`,
      ...(activityKind ? [`activity_kind=${activityKind}`] : []),
      ...(streamActive === undefined ? [] : [`stream_active=${streamActive}`]),
      ...(completedAssistantPresentationTail === undefined
        ? []
        : [`completed_assistant_presentation_tail=${completedAssistantPresentationTail}`]),
      ...(contains ? [`contains=${contains}`] : []),
      "",
    ].join("\n"),
  );
}

async function waitForCheckpoint(artifactDir: string) {
  await waitFor(
    () => existsSync(join(artifactDir, "checkpoint.json")),
    "observer checkpoint",
  );
}

function checkpointRecord(artifactDir: string): Record<string, unknown> {
  return JSON.parse(readFileSync(join(artifactDir, "checkpoint.json"), "utf8")) as Record<string, unknown>;
}

async function captureArtifacts(
  context: ScenarioContext,
  scenario: ScenarioName,
) {
  writeFileSync(join(context.artifactDir, "pane.txt"), await context.session.capturePane());
  writeFileSync(join(context.artifactDir, "pane.ansi.txt"), await context.session.capturePaneEscapes());
  writeFileSync(
    join(context.artifactDir, "scrollback.txt"),
    await context.session.captureFullScrollback(),
  );

  const checkpoint = checkpointRecord(context.artifactDir);
  const sequence = checkpoint.sequence;
  const marker = `ui-observer:${scenario}:${context.checkpoint}:frame:${sequence}`;
  const tapePath = join(context.artifactDir, "session.fxtp");
  const replayDir = join(context.artifactDir, "replay");
  execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", replayDir], {
    cwd: context.artifactDir,
    stdio: "pipe",
  });
  const markerFrame = readTapeFrames(tapePath).find(
    (frame) => frame.kind === 5 && frame.payload.toString("utf8") === marker,
  );
  if (!markerFrame) throw new Error(`replay marker not found: ${marker}`);
  writeFileSync(
    join(context.artifactDir, "marker.json"),
    JSON.stringify({ label: marker, tape_frame: markerFrame.index }, null, 2) + "\n",
  );
  const markerName = String(markerFrame.index).padStart(4, "0");
  const markerGrid = join(replayDir, "frames", `${markerName}.grid.txt`);
  if (existsSync(markerGrid)) {
    copyFileSync(markerGrid, join(context.artifactDir, "checkpoint.grid.txt"));
  }
}

function selectedRecord(artifactDir: string): Record<string, unknown> {
  const checkpoint = checkpointRecord(artifactDir);
  const sequence = checkpoint.sequence;
  const record = frameRecords(artifactDir).find((frame) => frame.sequence === sequence);
  if (!record) throw new Error(`selected sequence ${sequence} is missing from frames.jsonl`);
  return record;
}

function hasActivityKind(record: Record<string, unknown>, expected: ActivityKind) {
  const activity = record.activity;
  return typeof activity === "object" &&
    activity !== null &&
    !Array.isArray(activity) &&
    (activity as Record<string, unknown>).kind === expected;
}

function recordContains(record: Record<string, unknown>, text: string) {
  return JSON.stringify(record).includes(text);
}

async function setupScenario(
  scenario: ScenarioName,
  fixture: ReturnType<typeof createFixtureRoot>,
  artifactDir: string,
  size: { width: number; height: number },
): Promise<ScenarioContext> {
  let gateway: ReturnType<typeof startFakeGateway>;
  let checkpoint = scenario;
  let armKind: ArmKind = "normal";
  let activityKind: ActivityKind | undefined;
  let streamActive: boolean | undefined;
  let completedAssistantPresentationTail: boolean | undefined;
  let contains: string | undefined;
  let trigger: () => Promise<void> = async () => {};
  let expected: (record: Record<string, unknown>) => boolean = () => true;

  switch (scenario) {
    case "idle-composer": {
      gateway = startFakeGateway([]);
      trigger = async () => {
        await session.sendLiteralText("observer idle input");
      };
      contains = "observer idle input";
      expected = (record) => recordContains(record, "observer idle input");
      break;
    }
    case "streaming-assistant": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayFinalText("OBSERVER_STREAM_LATCH");
        },
      ]);
      trigger = async () => gate.release();
      contains = "OBSERVER_STREAM";
      activityKind = "turn_thinking";
      streamActive = false;
      completedAssistantPresentationTail = true;
      expected = (record) =>
        recordContains(record, "OBSERVER_STREAM") &&
        hasActivityKind(record, "turn_thinking") &&
        record.stream_active === false &&
        record.completed_assistant_presentation_tail === true;
      break;
    }
    case "markdown": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayFinalText(
            [
            "Observer Setext H1\n==================\n\nObserver Setext H2\n------------------\n\n## Observer markdown\n\nInline **bold**, *italic*, _underscore italic_, __underscore strong__, ~~struck~~, and `inline code spans a narrow terminal row` stay visible. _https://example.com/snake_case_ leaves its outer delimiter outside the link; snake__case stays literal.\n\nEscaped \\*emphasis\\*, \\*\\*bold\\*\\*, \\[literal link](https://example.com/escaped), and \\\\ remain literal.\n\nObserver hard break first\\\nObserver hard break second.\n\n- [ ] pending observer task\n- [x] completed observer task\n1. [X] ordered completed observer task\n  - [ ] nested observer task that wraps across a narrow terminal without losing its continuation indentation\n\nObserver status\n: **Running** with [details](https://example.com/observer-status).\n: A second definition wraps across the narrow observer terminal while retaining its continuation indentation.\n\n> > Nested observer quote wraps at narrow widths while preserving both vertical rules on every continuation row.\nLazy observer quote continuation preserves both rules without repeating source markers.\n\nRead [the observer link](https://example.com/observer), https://example.com/observer/a/path/that-wraps-on-narrow-terminals, <https://example.com/observer-angle-autolink>, and <observer@example.com>.\n\n![observer architecture diagram with a deliberately long label](https://example.com/observer-diagram.png) and ![](https://example.com/empty-alt.png)\n\n| Name | Value |\n| --- | --- |\n| observer-table-heading | 42 |\n| literal \\| pipe | escaped cell |\n| ![table image](https://example.com/table-image.png) | image cell |\n\n```Zig\nconst observer_zig = \"ready\"; // 1\n```\n\n```TypeScript\nconst observerType: string = \"ready\"; // 2\n```\n\n```json\n{\"observerJson\": \"ready\", \"count\": 3, \"enabled\": true}\n```\n\n```bash\nif true; then echo \"ready\"; fi # OBS_SH\n```\n\n~~~zig\nconst TILDE_OK = true;\n~~~\n",
              "\n\n[^observer-first]: This definition appears before its reference and ends with FOOTNOTE_DONE.\n\nForward observer reference[^observer-forward], repeated observer reference[^observer-forward], and definition-first reference[^observer-first].\n\n[^observer-forward]: The deferred body wraps through a narrow terminal while preserving its hanging indentation.\n  This observer continuation stays inside the deferred footnote body.\n",
            ].join(""),
          );
        },
      ]);
      trigger = async () => gate.release();
      contains = "FOOTNOTE_DONE";
      expected = (record) => recordContains(record, "FOOTNOTE_DONE");
      break;
    }
    case "file-approval": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayToolCall("observer_write", "write_file", {
            path: "observer-full-diff.txt",
            content: Array.from(
              { length: 32 },
              (_, index) => `observer-diff-line-${index + 1}`,
            ).join("\n") + "\n",
          });
        },
      ]);
      checkpoint = "approval";
      armKind = "alternate_screen";
      trigger = async () => gate.release();
      expected = (record) =>
        record.kind === "alternate_screen" &&
        record.file_identity_visible === true &&
        record.all_decision_controls_visible === true;
      break;
    }
    case "question": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayToolCall("observer_question", "ask_user_question", {
            questions: [
              {
                question: "Observer question checkpoint?",
                options: [
                  { label: "First choice", description: "First observer option." },
                  { label: "Second choice", description: "Second observer option." },
                ],
              },
            ],
          });
        },
      ]);
      trigger = async () => gate.release();
      contains = "Observer question checkpoint?";
      expected = (record) => recordContains(record, "Observer question checkpoint?");
      break;
    }
    case "resize": {
      gateway = startFakeGateway([]);
      checkpoint = "post-resize";
      trigger = async () => {
        await session.resizeWindow(100, 30);
      };
      expected = (record) => record.cols === 100 && record.rows === 30;
      break;
    }
    case "thinking-shimmer": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayFinalText("OBSERVER_THINKING_SHIMMER_RELEASED");
        },
      ]);
      checkpoint = "shimmer";
      activityKind = "turn_thinking";
      contains = "thinking";
      expected = (record) =>
        hasActivityKind(record, "turn_thinking") &&
        recordContains(record, "thinking");
      break;
    }
    case "thinking-running": {
      const gate = deferred();
      const finish = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeShellRun(
            "observer_thinking_running",
            "sleep 5 # this command is intentionally verbose so the running status must end with an omission marker at the terminal boundary",
            { timeout_ms: 600_000 },
          );
        },
        async () => {
          await finish.promise;
          return fakeGatewayFinalText("OBSERVER_THINKING_RUNNING_RELEASED");
        },
      ]);
      checkpoint = "running";
      activityKind = "tool_slot";
      contains = "Running sleep 5";
      trigger = async () => gate.release();
      expected = (record) =>
        hasActivityKind(record, "tool_slot") &&
        recordContains(record, "Running sleep 5") &&
        recordContains(record, "Thinking");
      break;
    }
    case "thinking-final": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeShellRun(
            "observer_thinking_final",
            "printf OBSERVER_THINKING_TOOL_FINAL # this command is intentionally verbose so the completed status must wrap and truncate at the terminal boundary",
            { timeout_ms: 600_000 },
          );
        },
        () => fakeGatewayFinalText("OBSERVER_THINKING_FINAL_RESPONSE"),
      ]);
      checkpoint = "final";
      activityKind = "none";
      contains = "(↑";
      trigger = async () => gate.release();
      expected = (record) =>
        hasActivityKind(record, "none") &&
        recordContains(record, "Ran printf OBSERVER_THINKING_TOOL_FINAL") &&
        recordContains(record, "OBSERVER_THINKING_FINAL_RESPONSE") &&
        recordContains(record, "(↑") &&
        recordContains(record, " ↓") &&
        !recordContains(record, "Thought for");
      break;
    }
    case "thinking-failed": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeShellRun(
            "observer_thinking_failed",
            "sh -c 'printf OBSERVER_THINKING_TOOL_FAILED >&2; exit 17' # this command is intentionally verbose so the failed status must wrap and truncate at the terminal boundary",
            { timeout_ms: 600_000 },
          );
        },
        () => fakeGatewayFinalText("OBSERVER_THINKING_FAILED_RESPONSE"),
      ]);
      checkpoint = "failed";
      activityKind = "none";
      contains = "(↑";
      trigger = async () => gate.release();
      expected = (record) =>
        hasActivityKind(record, "none") &&
        recordContains(record, "Failed sh -c") &&
        recordContains(record, "OBSERVER_THINKING_FAILED_RESPONSE") &&
        recordContains(record, "(↑") &&
        recordContains(record, " ↓") &&
        !recordContains(record, "Thought for");
      break;
    }
    case "thinking-none": {
      gateway = startFakeGateway([]);
      checkpoint = "none";
      activityKind = "none";
      contains = "OBSERVER_THINKING_NONE";
      trigger = async () => {
        await session.sendLiteralText("OBSERVER_THINKING_NONE");
      };
      expected = (record) =>
        hasActivityKind(record, "none") &&
        recordContains(record, "OBSERVER_THINKING_NONE");
      break;
    }
    case "tool-denied": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayToolCall("observer_denied", "write_file", {
            path: "observer-denied.txt",
            content: "denied\n",
          });
        },
        () => fakeGatewayFinalText("OBSERVER_TOOL_DENIED_COMPLETE"),
      ]);
      checkpoint = "denied";
      activityKind = "none";
      contains = "⊘";
      trigger = async () => {
        gate.release();
        await session.waitForText("Apply this change?", TIMEOUT_MS);
        await session.sendKeys("3");
        await session.sendKeys("Enter");
      };
      expected = (record) =>
        hasActivityKind(record, "none") &&
        recordContains(record, "⊘") &&
        recordContains(record, "Denied");
      break;
    }
    case "tool-cancelled": {
      const gate = deferred();
      gateway = startFakeGateway([
        async () => {
          await gate.promise;
          return fakeGatewayToolCall("observer_cancelled", "write_file", {
            path: "observer-cancelled.txt",
            content: "cancelled\n",
          });
        },
      ]);
      checkpoint = "cancelled";
      activityKind = "none";
      contains = "■";
      trigger = async () => {
        gate.release();
        await session.waitForText("Apply this change?", TIMEOUT_MS);
        await session.sendKeys("Escape");
      };
      expected = (record) =>
        hasActivityKind(record, "none") &&
        recordContains(record, "■") &&
        recordContains(record, "Cancelled");
      break;
    }
  }

  const session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: fixture.workspace,
    env: gatewayEnv(fixture, gateway, artifactDir),
    width: size.width,
    height: size.height,
    minimumHistoryLines: 5_000,
  });
  await session.waitForComposer(TIMEOUT_MS);

  if (
    scenario === "streaming-assistant" ||
    scenario === "markdown" ||
    scenario === "file-approval" ||
    scenario === "question" ||
    scenario === "thinking-shimmer" ||
    scenario === "thinking-running" ||
    scenario === "thinking-final" ||
    scenario === "thinking-failed" ||
    scenario === "tool-denied" ||
    scenario === "tool-cancelled"
  ) {
    await session.sendText(`start ${scenario}`);
    await waitFor(() => gateway.requests.length === 1, `${scenario} gateway request`);
  }

  return {
    workspace: fixture.workspace,
    artifactDir,
    session,
    gateway,
    checkpoint,
    armKind,
    activityKind,
    streamActive,
    completedAssistantPresentationTail,
    contains,
    trigger,
    expected,
  };
}

async function run() {
  const args = parseArgs();
  if (args.list) {
    for (const scenario of [
      "idle-composer",
      "streaming-assistant",
      "markdown",
      "file-approval",
      "question",
      "thinking-shimmer",
      "thinking-running",
      "thinking-final",
      "thinking-failed",
      "thinking-none",
      "tool-denied",
      "tool-cancelled",
      "resize",
    ] satisfies ScenarioName[]) {
      console.log(scenario);
    }
    return;
  }
  if (!args.scenario) throw new Error("--scenario is required");
  if (!tmuxAvailable()) throw new Error("tmux is required");
  if (!existsSync(FX_BIN)) {
    throw new Error(`fresh fx binary is missing: ${FX_BIN}\nRun: zig build`);
  }

  const fixture = createFixtureRoot(
    args.scenario === "thinking-running" ||
      args.scenario === "thinking-final" ||
      args.scenario === "thinking-failed",
  );
  const artifactDir = createArtifactDir(args.keep);
  let context: ScenarioContext | null = null;
  const preserveArtifacts = args.keep || process.env.FX_UI_OBSERVER_ARTIFACT_DIR !== undefined;
  try {
    context = await setupScenario(args.scenario, fixture, artifactDir, args.size);
    await waitFor(() => frameRecords(artifactDir).length > 0, "initial observer frame");
    if (
      args.scenario === "thinking-shimmer" ||
      args.scenario === "thinking-running" ||
      args.scenario === "thinking-final" ||
      args.scenario === "thinking-failed"
    ) {
      await waitFor(
        () => frameRecords(artifactDir).some((record) => hasActivityKind(record, "turn_thinking")),
        "initial thinking frame",
      );
    }
    writeArm(
      artifactDir,
      args.scenario,
      context.checkpoint,
      context.armKind,
      lastSequence(artifactDir),
      context.activityKind,
      context.streamActive,
      context.completedAssistantPresentationTail,
      context.contains,
    );
    await context.trigger();
    await waitForCheckpoint(artifactDir);
    const record = selectedRecord(artifactDir);
    if (!context.expected(record)) {
      throw new Error(
        `checkpoint selected the wrong frame:\n${JSON.stringify(record, null, 2)}`,
      );
    }
    await captureArtifacts(context, args.scenario);

    console.log(`observer artifacts: ${artifactDir}`);
    console.log(`tmux session: ${context.session.name}`);
    if (args.hold) {
      console.log(`attach: tmux attach -t ${context.session.name}`);
      console.log(`release: touch ${join(artifactDir, "release")}`);
      await new Promise<never>(() => {});
    }

    writeFileSync(join(artifactDir, "release"), "");
  } finally {
    if (context && !args.hold) {
      await context.session.kill();
      context.gateway.stop();
    }
    rmSync(fixture.root, { recursive: true, force: true });
    if (!preserveArtifacts) rmSync(artifactDir, { recursive: true, force: true });
  }
}

await run();
