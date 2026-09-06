import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { FX_BIN, REPO_ROOT } from "../../evals/eval-helpers";
import { isVolatileTokenStatusRow } from "../tmux-helpers";
import {
  ACTIVE_TOOL_MARKER,
  analyzeRun,
  commandMoreCount,
  findFooters,
  readQuiescence,
  TERMINAL_TOOL_MARKER,
  traceCountersFromTrace,
} from "./analyzer";
import type {
  RenderLabTraceCounters,
} from "./analyzer";
import {
  attachFrameEvidence,
  runtimeEvidenceDefaults,
  waitForStableProbe,
  writeRuntimeEvidence,
} from "./evidence";
import {
  isNativeScenario,
  nativeScenarioHelpLines,
  nativeScenarioNames,
  runNativeRenderLab,
} from "./native";
import { writeReport } from "./report";
import type {
  RenderLabBenchmark,
  RenderLabBenchmarkSizeResult,
  RenderLabFailure,
  RenderLabFrame,
  RenderLabFrameManifest,
  RenderLabManifest,
  RenderLabNumericStats,
  RenderLabTerminalSize,
  RenderLabTimingStats,
} from "./types";

type Options = {
  scenario: string;
  runs: number;
  out: string;
  analyze: string | null;
  listScenarios: boolean;
  sizes: RenderLabTerminalSize[] | null;
};

type Fixture = {
  root: string;
  home: string;
  zdotdir: string;
  work: string;
  histfile: string;
};

type ScenarioContext = {
  fixture: Fixture;
  manifest: RenderLabManifest;
  binarySha256: string;
};

type FxLaunchOptions = {
  stderrPath?: string;
  gatewayApiKey?: string;
  gatewayChatUrl?: string;
  gatewayModelsUrl?: string;
  permissionMode?: "ask" | "auto" | "yolo";
};

type LocalGatewayFixture = {
  chatUrl: string;
  modelsUrl: string;
  requests: string[];
  releaseResponse(): void;
  stop(): void;
};

function gatewaySse(events: object[]): Response {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function permissionDecisionResponse(): Response {
  return gatewaySse([
    {
      type: "tool-call",
      toolCallId: "render_lab_permission_decision_1",
      toolName: "permission_decision",
      input: {
        risk: "low",
        decision: "clear",
        rationale: "deterministic render-lab decision",
      },
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

const SCENARIO = "same-shell-relaunch";
const BUFFER_SYSTEM_FRAME_BENCH = "buffer-system-frame-bench";
const STARTUP_SCROLLBACK_DISABLED_OVERFLOW = "startup-scrollback-disabled-overflow";
const STARTUP_SCROLLBACK_ENABLED_OVERFLOW = "startup-scrollback-enabled-overflow";
const ACTIVE_TOOL_PLACEMENT = "active-tool-placement";
const USER_CARD_RESIZE_REPLAY_SCROLLBACK = "user-card-resize-replay-scrollback";
const TUI_OBSERVABILITY_GAUNTLET = "tui-observability-gauntlet";
const LOCAL_GATEWAY_COMPLETION = "RENDER_LAB_LOCAL_GATEWAY_OK";
const OBSERVABILITY_TRANSCRIPT_HEAD = "OBSERVABILITY_TRANSCRIPT_HEAD";
const OBSERVABILITY_TRANSCRIPT_TAIL = "OBSERVABILITY_TRANSCRIPT_TAIL";
const OBSERVABILITY_FINAL_MARKER = "OBSERVABILITY_FINAL_RESPONSE";
const OBSERVABILITY_PERMISSION_PROMPT = "Would you like to run the following command?";
const OBSERVABILITY_PERMISSION_REVIEW = "Permission needed";
const OBSERVABILITY_TOOL_COMMAND = "touch render-lab-observability-approved.txt";
const LOCAL_GATEWAY_CHAT_PATH = "/v3/ai/language-model";
const LOCAL_GATEWAY_MODELS_PATH = "/coding-agent/v1/models";
const DEFAULT_BENCH_SIZES: RenderLabTerminalSize[] = [
  { cols: 80, rows: 24 },
  { cols: 120, rows: 40 },
  { cols: 200, rows: 80 },
];
const BENCHMARK_COMBINED_P95_LIMIT_MS = 8;
const BENCHMARK_P95_MIN_RUNS = 20;
const PROMPT_TEXT = "FX_RENDER_LAB%";
const TRACE_SCOPES =
  "render,paint,resize,scroll,footer.clean,input,permission,frame_layout,frame_plan,frame_diff,frame_commit,frame_owner_violation,frame_schedule,ui_activity";
const QUIESCENCE_INTERVAL_MS = 300;
const ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS = 30_000;

export async function runRenderLab(rawOptions: Partial<Options> = {}): Promise<RenderLabManifest[]> {
  const options = {
    scenario: rawOptions.scenario ?? SCENARIO,
    runs: rawOptions.runs ?? 1,
    out: rawOptions.out ?? join(shortTempBase(), "fx-render-lab-artifacts"),
    analyze: rawOptions.analyze ?? null,
    listScenarios: rawOptions.listScenarios ?? false,
    sizes: rawOptions.sizes ?? null,
  };

  if (options.analyze) {
    return analyzeExisting(options.analyze);
  }

  if (options.runs < 1) throw new Error("--runs must be at least 1");

  mkdirSync(options.out, { recursive: true });
  if (options.scenario === BUFFER_SYSTEM_FRAME_BENCH) {
    const manifest = runBufferSystemFrameBench(
      options.out,
      options.runs,
      options.sizes ?? DEFAULT_BENCH_SIZES,
    );
    if (manifest.failures.length > 0) {
      throw new Error(`render-lab benchmark failed; see ${manifest.artifactDir}`);
    }
    return [manifest];
  }

  const results: RenderLabManifest[] = [];
  for (let i = 0; i < options.runs; i += 1) {
    if (options.scenario === SCENARIO) {
      results.push(await runSameShellRelaunch(options.out, i + 1));
    } else if (options.scenario === ACTIVE_TOOL_PLACEMENT) {
      results.push(await runActiveToolPlacement(options.out, i + 1));
    } else if (options.scenario === USER_CARD_RESIZE_REPLAY_SCROLLBACK) {
      results.push(await runUserCardResizeReplayScrollback(options.out, i + 1));
    } else if (options.scenario === TUI_OBSERVABILITY_GAUNTLET) {
      results.push(await runTuiObservabilityGauntlet(options.out, i + 1));
    } else if (
      options.scenario === STARTUP_SCROLLBACK_DISABLED_OVERFLOW ||
      options.scenario === STARTUP_SCROLLBACK_ENABLED_OVERFLOW
    ) {
      results.push(
        await runStartupScrollbackOverflow(
          options.out,
          i + 1,
          options.scenario === STARTUP_SCROLLBACK_ENABLED_OVERFLOW,
        ),
      );
    } else if (isNativeScenario(options.scenario)) {
      results.push(await runNativeRenderLab(options.scenario, options.out, i + 1));
    } else {
      throw new Error(
        `unknown render-lab scenario: ${options.scenario}\nknown scenarios: ${[
          SCENARIO,
          BUFFER_SYSTEM_FRAME_BENCH,
          ACTIVE_TOOL_PLACEMENT,
          USER_CARD_RESIZE_REPLAY_SCROLLBACK,
          TUI_OBSERVABILITY_GAUNTLET,
          STARTUP_SCROLLBACK_DISABLED_OVERFLOW,
          STARTUP_SCROLLBACK_ENABLED_OVERFLOW,
          ...nativeScenarioNames(),
        ].join(", ")}`,
      );
    }
  }
  const failures = results.flatMap((manifest) => manifest.failures);
  if (failures.length > 0) {
    const details = failures
      .map((failure) => `${failure.invariant} (${failure.event}): ${failure.message}`)
      .join("\n");
    throw new Error(
      `render-lab found ${failures.length} failure(s):\n${details}\nsee ${results[0]?.artifactDir}`,
    );
  }
  return results;
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  if (options.listScenarios) {
    printScenarioList();
    return;
  }
  const manifests = await runRenderLab(options);
  for (const manifest of manifests) {
    console.log(`render-lab ${manifest.scenario}: ${manifest.artifactDir}`);
    if (manifest.failures.length > 0) {
      console.log(`  failures: ${manifest.failures.length}`);
    }
  }
}

async function runSameShellRelaunch(outRoot: string, runNumber: number): Promise<RenderLabManifest> {
  preflight();

  const startedAt = new Date();
  const runId = `${SCENARIO}-${timestampForPath(startedAt)}-${runNumber}-${randomBytes(3).toString("hex")}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const manifest: RenderLabManifest = {
    version: 1,
    scenario: SCENARIO,
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
      shell: [
        `SHELL_A_BEFORE_FIRST_${runId}`,
        `SHELL_A_BETWEEN_LAUNCHES_${runId}`,
        `SHELL_A_BEFORE_THIRD_${runId}`,
      ],
      clearedShell: [
        `SHELL_A_BEFORE_FIRST_${runId}`,
        `SHELL_A_BETWEEN_LAUNCHES_${runId}`,
      ],
      submitted: ["permission_mode", "● Version:", "/help"],
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest);

  const fixture = createFixture(runId);
  let session: RenderLabTmux | null = null;
  try {
    session = await RenderLabTmux.create({
      fixture,
      manifest,
      width: 120,
      height: 40,
    });
    const context = { fixture, manifest, binarySha256 };

    await capture(context, session, "shell-started");
    await runShellCommand(context, session, "pwd", fixture.work, "shell-pwd");
    await runShellCommand(
      context,
      session,
      `printf '%s\\n' "$SHELL_A_BEFORE_FIRST"`,
      manifest.markers.shell[0]!,
      "shell-before-first",
    );
    await runShellCommand(
      context,
      session,
      `printf '%s\\n' ${shQuote(longLine(runId, "first"))}`,
      "first-11",
      "shell-long-line-before-first",
    );

    await launchFx(context, session, "first");
    await submitSlashCommand(context, session, "/status", "permission_mode", "first-status-visible");
    await quitFx(context, session, "first");

    await runShellCommand(
      context,
      session,
      `printf '%s\\n' "$SHELL_A_BETWEEN_LAUNCHES"`,
      manifest.markers.shell[1]!,
      "shell-between-launches",
    );
    await runShellCommand(
      context,
      session,
      `printf '%s\\n' ${shQuote(longLine(runId, "second"))}`,
      "second-11",
      "shell-long-line-between-launches",
    );

    await launchFx(context, session, "second");
    await submitSlashCommand(context, session, "/version", "● Version:", "second-version-visible");
    await resize(context, session, 72, 24, "second-resize-narrow");
    await resize(context, session, 132, 42, "second-resize-wide");
    await resize(context, session, 120, 40, "second-resize-restored");
    await quitFx(context, session, "second");

    await runShellCommand(
      context,
      session,
      `printf '%s\\n' "$SHELL_A_BEFORE_THIRD"`,
      manifest.markers.shell[2]!,
      "shell-before-third",
    );

    await launchFx(context, session, "third");
    await submitSlashCommand(context, session, "/help", "/version", "third-help-visible");
    const finalFrame = await capture(context, session, "final-third-launch-state");
    manifest.finalFrameIndex = finalFrame.index;

    await quitFx(context, session, "third-cleanup");
    await session.sendText("exit");
    await session.waitForEnd(10_000);
    session = null;

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
      invariant: "scenario-error",
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
    if (session) await session.kill();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function runActiveToolPlacement(
  outRoot: string,
  runNumber: number,
): Promise<RenderLabManifest> {
  preflight();

  const scenario = ACTIVE_TOOL_PLACEMENT;
  const startedAt = new Date();
  const markerSuffix = randomBytes(4).toString("hex");
  const runId = `${scenario}-${timestampForPath(startedAt)}-${runNumber}-${markerSuffix}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const manifest: RenderLabManifest = {
    version: 1,
    scenario,
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
      shell: [],
      submitted: ["exercise one active command placement"],
      history: ["Run /help for commands"],
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest);

  const fixture = createFixture(runId);
  const activeToolReleasePath = join(fixture.work, ".active-tool-release");
  const gateway = startActiveToolGatewayFixture();
  let session: RenderLabTmux | null = null;
  try {
    session = await RenderLabTmux.create({
      fixture,
      manifest,
      width: 100,
      height: 52,
    });
    const context = { fixture, manifest, binarySha256 };

    await launchFx(context, session, "active-tool", {
      stderrPath: join(artifactDir, "stderr.log"),
      gatewayApiKey: "render-lab-local-gateway-key",
      gatewayChatUrl: gateway.chatUrl,
      gatewayModelsUrl: gateway.modelsUrl,
    });
    await submitSlashCommand(
      context,
      session,
      "/permissions auto",
      "auto",
      "active-tool-permissions-auto",
    );

    await session.sendText("exercise one active command placement");
    await waitForLocalGatewayRequest(
      gateway.requests,
      `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
      10_000,
    );
    await session.waitForPane(
      (pane) => pane.includes(ACTIVE_TOOL_MARKER),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    await capture(context, session, "active-tool-visible");

    await session.resize(80, 18);
    await session.waitForPane(
      (pane) => pane.includes(ACTIVE_TOOL_MARKER),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    await capture(context, session, "active-tool-clipped");

    writeFileSync(activeToolReleasePath, "");
    await session.waitForPane(
      (pane) => pane.includes(TERMINAL_TOOL_MARKER),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    await session.resize(80, 5);
    const suppressedProbe = await session.waitForStableVisibleState();
    if (!suppressedProbe.stable) {
      throw new Error("active tool suppressed-animation state did not settle");
    }
    await recordQuiescentInterval(
      manifest,
      "active-tool-suppressed-animation",
      QUIESCENCE_INTERVAL_MS,
    );

    await session.resize(100, 52);
    await session.waitForPane(
      (pane) => pane.includes(TERMINAL_TOOL_MARKER),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    const resized = await capture(context, session, "active-tool-resized-visible");
    manifest.finalFrameIndex = resized.index;

    await waitForLocalGatewayRequestCount(
      gateway.requests,
      `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
      2,
      30_000,
    );
    await capture(context, session, "active-tool-terminal");

    await session.sendKeys("C-o");
    await session.waitForPane(
      (pane) => pane.includes("┃ Full detail · ctrl o close"),
      10_000,
    );
    await captureMatching(
      context,
      session,
      "active-tool-command-output-expanded",
      (pane) => pane.includes("ACTIVE_TOOL_LINE_32") && commandMoreCount(pane) === null,
      10_000,
    );

    let resizeTraceOffset = readOptional(manifest.traceLogPath).length;
    await session.resize(80, 18);
    await waitForFileText(
      manifest.traceLogPath,
      (trace) => trace.slice(resizeTraceOffset).includes(
        "apply old=100x52 new=80x18 size_changed=true",
      ),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    await captureMatching(
      context,
      session,
      "active-tool-command-output-expanded-shrink",
      (pane) =>
        pane.includes("┃ Full detail · ctrl o close") &&
        commandMoreCount(pane) === null,
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );

    resizeTraceOffset = readOptional(manifest.traceLogPath).length;
    await session.resize(100, 52);
    await waitForFileText(
      manifest.traceLogPath,
      (trace) => trace.slice(resizeTraceOffset).includes(
        "apply old=80x18 new=100x52 size_changed=true",
      ),
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );
    await captureMatching(
      context,
      session,
      "active-tool-command-output-expanded-grow",
      (pane) => pane.includes("ACTIVE_TOOL_LINE_32") && commandMoreCount(pane) === null,
      ACTIVE_TOOL_RESIZE_CAPTURE_TIMEOUT_MS,
    );

    await session.sendKeys("C-o");
    await captureMatching(
      context,
      session,
      "active-tool-command-output-collapsed-again",
      (pane) =>
        pane.includes(TERMINAL_TOOL_MARKER) &&
        commandMoreCount(pane) === null &&
        !pane.includes("ACTIVE_TOOL_LINE_32"),
      10_000,
    );

    gateway.releaseResponse();
    await session.waitForPane((pane) => pane.includes(LOCAL_GATEWAY_COMPLETION), 15_000);
    const finalUpdate = await capture(context, session, "active-tool-final-update");
    manifest.finalFrameIndex = finalUpdate.index;

    await quitFx(context, session, "active-tool-cleanup");
    await session.sendText("exit");
    await session.waitForEnd(10_000);
    session = null;

    const postRequests = gateway.requests.filter(
      (request) => request === `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
    );
    if (postRequests.length !== 2) {
      throw new Error(`expected two gateway chat requests, found ${postRequests.length}`);
    }

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
      invariant: "scenario-error",
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
    if (session) await session.kill();
    gateway.stop();
    writeFileSync(
      join(artifactDir, "gateway-requests.log"),
      `${gateway.requests.join("\n")}\n`,
    );
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function runUserCardResizeReplayScrollback(
  outRoot: string,
  runNumber: number,
): Promise<RenderLabManifest> {
  preflight();

  const scenario = USER_CARD_RESIZE_REPLAY_SCROLLBACK;
  const startedAt = new Date();
  const markerSuffix = randomBytes(4).toString("hex");
  const runId = `${scenario}-${timestampForPath(startedAt)}-${runNumber}-${markerSuffix}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const promptHead = `USER_CARD_HEAD_${markerSuffix}`;
  const promptTail = `USER_CARD_TAIL_${markerSuffix}`;
  const prompt = [
    promptHead,
    "This submitted prompt must reflow across narrow and wide terminal sizes",
    "without duplicating either the user card or the startup banner in scrollback.",
    promptTail,
  ].join(" ");
  const manifest: RenderLabManifest = {
    version: 1,
    scenario,
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
      shell: [],
      submitted: [promptHead, promptTail],
      history: ["Run /help for commands"],
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest);

  const fixture = createFixture(runId);
  const gateway = startLocalGatewayFixture(promptTail);
  let session: RenderLabTmux | null = null;
  try {
    session = await RenderLabTmux.create({
      fixture,
      manifest,
      width: 120,
      height: 40,
    });
    const context = { fixture, manifest, binarySha256 };

    await launchFx(context, session, "user-card", {
      stderrPath: join(artifactDir, "stderr.log"),
      gatewayApiKey: "render-lab-local-gateway-key",
      gatewayChatUrl: gateway.chatUrl,
      gatewayModelsUrl: gateway.modelsUrl,
    });
    await session.sendText(prompt);
    await waitForLocalGatewayRequest(
      gateway.requests,
      `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
      10_000,
    );
    gateway.releaseResponse();
    await session.waitForPane(
      (pane) => pane.includes(promptTail) && pane.includes(LOCAL_GATEWAY_COMPLETION),
      10_000,
    );
    await capture(context, session, "user-card-wide");

    await session.resize(76, 24);
    await session.waitForPane((pane) => pane.includes(promptTail), 10_000);
    await capture(context, session, "user-card-resized-narrow");

    await session.resize(132, 42);
    await session.waitForPane((pane) => pane.includes(promptTail), 10_000);
    const finalFrame = await capture(context, session, "user-card-resized-wide");
    manifest.finalFrameIndex = finalFrame.index;
    await recordQuiescentInterval(
      manifest,
      "user-card-resized-wide-quiescent",
      QUIESCENCE_INTERVAL_MS,
    );

    await quitFx(context, session, "user-card-cleanup");
    await session.sendText("exit");
    await session.waitForEnd(10_000);
    session = null;
    assertLocalGatewayRequests(gateway.requests);

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
      invariant: "scenario-error",
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
    if (session) await session.kill();
    gateway.releaseResponse();
    gateway.stop();
    writeFileSync(join(artifactDir, "gateway-requests.log"), `${gateway.requests.join("\n")}\n`);
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function runTuiObservabilityGauntlet(
  outRoot: string,
  runNumber: number,
): Promise<RenderLabManifest> {
  preflight();

  const scenario = TUI_OBSERVABILITY_GAUNTLET;
  const startedAt = new Date();
  const markerSuffix = randomBytes(4).toString("hex");
  const runId = `${scenario}-${timestampForPath(startedAt)}-${runNumber}-${markerSuffix}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const shellMarker = `OBSERVABILITY_SHELL_HISTORY_${markerSuffix}`;
  const promptHead = `OBSERVABILITY_PROMPT_HEAD_${markerSuffix}`;
  const promptTail = `OBSERVABILITY_PROMPT_TAIL_${markerSuffix}`;
  const prompt = [
    promptHead,
    "exercise transcript, permission UI, tmux resize, scrollback, and final composer recovery",
    promptTail,
  ].join(" ");
  const manifest: RenderLabManifest = {
    version: 1,
    scenario,
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
      shell: [shellMarker],
      clearedShell: [shellMarker],
      submitted: [promptHead, promptTail],
      history: [
        "Run /help for commands",
        OBSERVABILITY_TRANSCRIPT_HEAD,
        OBSERVABILITY_TRANSCRIPT_TAIL,
        "OBSERVABILITY_TOOL_OUTPUT",
        OBSERVABILITY_FINAL_MARKER,
      ],
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest);

  const fixture = createFixture(runId);
  const gateway = startObservabilityGatewayFixture(promptTail);
  let session: RenderLabTmux | null = null;
  try {
    session = await RenderLabTmux.create({
      fixture,
      manifest,
      width: 120,
      height: 36,
    });
    const context = { fixture, manifest, binarySha256 };

    await runShellCommand(
      context,
      session,
      `printf '%s\\n' ${shQuote(shellMarker)}`,
      shellMarker,
      "observability-shell-seed",
    );

    await launchFx(context, session, "observability", {
      stderrPath: join(artifactDir, "stderr.log"),
      gatewayApiKey: "render-lab-local-gateway-key",
      gatewayChatUrl: gateway.chatUrl,
      gatewayModelsUrl: gateway.modelsUrl,
      permissionMode: "ask",
    });
    await session.sendText(prompt);
    await waitForLocalGatewayRequest(
      gateway.requests,
      `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
      10_000,
    );
    await session.waitForPane(
      (pane) =>
        pane.includes(OBSERVABILITY_PERMISSION_PROMPT) &&
        pane.includes(OBSERVABILITY_TRANSCRIPT_TAIL),
      15_000,
    );
    await capture(context, session, "observability-permission-inline");

    await session.resize(40, 13);
    await session.waitForPane(
      (pane) => pane.includes(OBSERVABILITY_PERMISSION_REVIEW),
      10_000,
    );
    await capture(context, session, "observability-permission-review");

    await session.resize(120, 36);
    await session.waitForPane(
      (pane) => pane.includes(OBSERVABILITY_PERMISSION_PROMPT),
      10_000,
    );
    await capture(context, session, "observability-permission-restored");

    await session.sendLiteral("1");
    await waitForLocalGatewayRequestCount(
      gateway.requests,
      `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
      2,
      20_000,
    );
    await session.waitForPane(
      (pane) => pane.includes("OBSERVABILITY_TOOL_OUTPUT"),
      10_000,
    );
    await capture(context, session, "observability-tool-completed");
    if (!existsSync(join(fixture.work, "render-lab-observability-approved.txt"))) {
      throw new Error("approved observability command did not execute");
    }

    gateway.releaseResponse();
    await session.waitForPane(
      (pane) => pane.includes(OBSERVABILITY_FINAL_MARKER),
      15_000,
    );
    await capture(context, session, "observability-final-wide");

    await session.resize(76, 24);
    await session.waitForPane(
      (pane) => pane.includes(OBSERVABILITY_FINAL_MARKER),
      10_000,
    );
    await capture(context, session, "observability-final-narrow");

    await session.resize(132, 42);
    await session.waitForPane(
      (pane) => pane.includes(OBSERVABILITY_FINAL_MARKER),
      10_000,
    );
    const finalFrame = await capture(
      context,
      session,
      "observability-final-restored",
    );
    manifest.finalFrameIndex = finalFrame.index;
    await recordQuiescentInterval(
      manifest,
      "observability-final-quiescent",
      QUIESCENCE_INTERVAL_MS,
    );

    await quitFx(context, session, "observability-cleanup");
    await session.sendText("exit");
    await session.waitForEnd(10_000);
    session = null;

    const postRequests = gateway.requests.filter(
      (request) => request === `POST ${LOCAL_GATEWAY_CHAT_PATH}`,
    );
    if (postRequests.length !== 2) {
      throw new Error(`expected two gateway chat requests, found ${postRequests.length}`);
    }

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
      invariant: "scenario-error",
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
    if (session) await session.kill();
    gateway.releaseResponse();
    gateway.stop();
    writeFileSync(
      join(artifactDir, "gateway-requests.log"),
      `${gateway.requests.join("\n")}\n`,
    );
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function recordQuiescentInterval(
  manifest: RenderLabManifest,
  event: string,
  durationMs: number,
): Promise<void> {
  const before = traceCountersFromTrace(readOptional(manifest.traceLogPath));
  await sleep(durationMs);
  const after = traceCountersFromTrace(readOptional(manifest.traceLogPath));
  const delta = subtractTraceCounters(after, before);
  const evidence = { event, durationMs, before, after, delta };
  writeFileSync(
    join(manifest.artifactDir, "quiescence.json"),
    `${JSON.stringify([...readQuiescence(manifest), evidence], null, 2)}\n`,
  );
  if ([delta.frameAttempts, delta.terminalDiffs, delta.terminalWrites, delta.invalidations].some(Boolean)) {
    throw new Error(`${event} performed frame work while quiescent: ${JSON.stringify(delta)}`);
  }
}

function subtractTraceCounters(
  after: RenderLabTraceCounters,
  before: RenderLabTraceCounters,
): RenderLabTraceCounters {
  const invalidationReasons: Record<string, number> = {};
  const reasons = new Set([
    ...Object.keys(before.invalidationReasons),
    ...Object.keys(after.invalidationReasons),
  ]);
  for (const reason of reasons) {
    const delta = (after.invalidationReasons[reason] ?? 0) -
      (before.invalidationReasons[reason] ?? 0);
    if (delta > 0) invalidationReasons[reason] = delta;
  }
  return {
    frameAttempts: Math.max(0, after.frameAttempts - before.frameAttempts),
    terminalDiffs: Math.max(0, after.terminalDiffs - before.terminalDiffs),
    terminalWrites: Math.max(0, after.terminalWrites - before.terminalWrites),
    invalidations: Math.max(0, after.invalidations - before.invalidations),
    invalidationReasons,
  };
}

function activeToolPlacement(
  grid: string[],
  marker: string,
  cursor: RenderLabFrame["cursor"] = null,
): "transcript" | "transient" | null {
  const markerRows = grid
    .map((row, index) => row.includes(marker) ? index : -1)
    .filter((index) => index >= 0);
  if (markerRows.length !== 1) return null;
  const footer = findFooters(grid, cursor)[0];
  if (!footer) return null;
  return markerRows[0] === footer.topDivider - 1 ? "transient" : "transcript";
}

async function runStartupScrollbackOverflow(
  outRoot: string,
  runNumber: number,
  startupScrollback: boolean,
): Promise<RenderLabManifest> {
  preflight();

  const scenario = startupScrollback
    ? STARTUP_SCROLLBACK_ENABLED_OVERFLOW
    : STARTUP_SCROLLBACK_DISABLED_OVERFLOW;
  const startedAt = new Date();
  const markerSuffix = randomBytes(4).toString("hex");
  const runId = `${scenario}-${timestampForPath(startedAt)}-${runNumber}-${markerSuffix}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-${runNumber}`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const promptHead = `OVERFLOW_PROMPT_HEAD_${markerSuffix}`;
  const promptTail = `OVERFLOW_PROMPT_TAIL_${markerSuffix}`;
  const manifest: RenderLabManifest = {
    version: 1,
    scenario,
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
      shell: [
        `SHELL_OVERFLOW_START_${markerSuffix}`,
        `SHELL_OVERFLOW_MIDDLE_${markerSuffix}`,
        `SHELL_OVERFLOW_END_${markerSuffix}`,
      ],
      submitted: [promptTail],
      history: [promptHead, "Run /help for commands"],
    },
    frames: [],
    failures: [],
  };
  writeManifest(manifest);
  writeReproScript(manifest);

  const fixture = createFixture(runId);
  mkdirSync(join(fixture.home, ".fx"), { recursive: true });
  writeFileSync(
    join(fixture.home, ".fx", "settings.json"),
    `${JSON.stringify({ startup_scrollback: startupScrollback })}\n`,
  );
  const gateway = startLocalGatewayFixture(promptTail);
  let session: RenderLabTmux | null = null;
  try {
    session = await RenderLabTmux.create({
      fixture,
      manifest,
      width: 88,
      height: 20,
    });
    const context = { fixture, manifest, binarySha256 };

    await runShellCommand(
      context,
      session,
      `printf '%s\\n' ${shQuote(manifest.markers.shell[0]!)}`,
      manifest.markers.shell[0]!,
      "overflow-shell-start",
    );
    await runShellCommand(
      context,
      session,
      "for i in {01..18}; do printf 'overflow-shell-filler-%s\\n' \"$i\"; done",
      "overflow-shell-filler-18",
      "overflow-shell-fillers",
    );
    await runShellCommand(
      context,
      session,
      `printf '%s\\n%s\\n' ${shQuote(manifest.markers.shell[1]!)} ${shQuote(manifest.markers.shell[2]!)}`,
      manifest.markers.shell[2]!,
      "overflow-shell-end",
    );

    await launchFx(context, session, "overflow", {
      stderrPath: join(artifactDir, "stderr.log"),
      gatewayApiKey: "render-lab-local-gateway-key",
      gatewayChatUrl: gateway.chatUrl,
      gatewayModelsUrl: gateway.modelsUrl,
    });
    await capture(context, session, "overflow-initial-bottom-anchored-frame");

    await session.sendLiteral("/");
    await capture(context, session, "overflow-slash-menu-expanded");
    await session.sendKeys("C-u");

    const prompt = [
      promptHead,
      ...Array.from({ length: 54 }, (_, index) => `pasted-overflow-${index + 1}`),
      promptTail,
    ].join("\n");
    await session.sendBracketedPaste(prompt);
    await session.waitForPane((pane) => pane.includes("[Pasted text #1, 56 lines]"), 10_000);
    await capture(context, session, "overflow-long-prompt-editor-tail-visible");

    await session.sendKeys("Enter");
    await waitForLocalGatewayRequest(gateway.requests, `POST ${LOCAL_GATEWAY_CHAT_PATH}`, 10_000);
    await session.waitForPane(
      (pane) =>
        pane.includes(promptTail) &&
        pane.split("\n").some((row) => /^┃\s*$/.test(row)),
      10_000,
    );
    const submittedFrame = await capture(context, session, "overflow-submitted-prompt-tail-visible");
    manifest.finalFrameIndex = submittedFrame.index;
    gateway.releaseResponse();
    await session.waitForPane((pane) => pane.includes(LOCAL_GATEWAY_COMPLETION), 10_000);

    await quitFx(context, session, "overflow-cleanup");
    await session.sendText("exit");
    await session.waitForEnd(10_000);
    session = null;
    assertLocalGatewayRequests(gateway.requests);

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
      invariant: "scenario-error",
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
    if (session) await session.kill();
    gateway.releaseResponse();
    gateway.stop();
    writeFileSync(join(artifactDir, "gateway-requests.log"), `${gateway.requests.join("\n")}\n`);
    rmSync(fixture.root, { recursive: true, force: true });
  }
}

async function analyzeExisting(path: string): Promise<RenderLabManifest[]> {
  const runDirs = resolveRunDirs(path);
  if (runDirs.length === 0) throw new Error(`no render-lab runs found under ${path}`);

  const manifests: RenderLabManifest[] = [];
  for (const runDir of runDirs) {
    const manifest = readManifest(join(runDir, "manifest.json"));
    const analysis = analyzeRun(manifest);
    manifest.failures = analysis.failures;
    manifest.completedAt = manifest.completedAt ?? new Date().toISOString();
    writeManifest(manifest);
    writeFailureFile(manifest);
    writeReport(manifest);
    manifests.push(manifest);
  }

  const failureCount = manifests.reduce((total, manifest) => total + manifest.failures.length, 0);
  if (failureCount > 0) throw new Error(`render-lab analysis found ${failureCount} failure(s)`);
  return manifests;
}

type BenchPlan = {
  size: RenderLabTerminalSize;
  transcriptTop: number;
  transcriptBottom: number;
  footerTop: number;
  footerBottom: number;
  activityRow: number | null;
  invalidationReason: string;
  fullRepaint: boolean;
  cursorRow: number;
  cursorCol: number;
};

type BenchCell = {
  code: number;
  owner: "preserved_shell" | "transcript" | "activity" | "footer";
  width: 0 | 1 | 2;
};

type BenchSurface = {
  size: RenderLabTerminalSize;
  cells: BenchCell[];
  cursorRow: number;
  cursorCol: number;
};

type BenchSample = {
  planMs: number;
  surfaceInitMs: number;
  paintMs: number;
  validateMs: number;
  diffMs: number;
  combinedMs: number;
  changedCells: number;
  diffBytes: number;
  fullRepaint: boolean;
  invalidationReason: string;
};

function runBufferSystemFrameBench(
  outRoot: string,
  runs: number,
  sizes: RenderLabTerminalSize[],
): RenderLabManifest {
  preflightBinaryOnly();
  if (sizes.length === 0) throw new Error("--sizes must contain at least one terminal size");
  const thresholdRequired = sizes.some((size) => size.cols === 200 && size.rows === 80);
  if (thresholdRequired && runs < BENCHMARK_P95_MIN_RUNS) {
    throw new Error(
      `buffer-system p95 threshold requires at least ${BENCHMARK_P95_MIN_RUNS} runs`,
    );
  }

  const startedAt = new Date();
  const runId = `${BUFFER_SYSTEM_FRAME_BENCH}-${timestampForPath(startedAt)}-${randomBytes(3).toString("hex")}`;
  const artifactDir = join(outRoot, `run-${timestampForPath(startedAt)}-bench`);
  mkdirSync(join(artifactDir, "replay", "frames"), { recursive: true });

  const binarySha256 = sha256(FX_BIN);
  const manifest: RenderLabManifest = {
    version: 1,
    scenario: BUFFER_SYSTEM_FRAME_BENCH,
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
      shell: [],
      submitted: [],
    },
    frames: [],
    failures: [],
  };

  const results = sizes.map((size) => runFrameBenchForSize(size, runs));
  const thresholdResult = results.find(
    (result) =>
      result.terminalSize.cols === 200 &&
      result.terminalSize.rows === 80,
  );
  const actualMs = thresholdResult?.timings.combined.p95Ms ?? null;
  const thresholdPassed =
    actualMs !== null && actualMs <= BENCHMARK_COMBINED_P95_LIMIT_MS;
  const benchmark: RenderLabBenchmark = {
    version: 1,
    scenario: BUFFER_SYSTEM_FRAME_BENCH,
    generatedAt: new Date().toISOString(),
    benchmarkPath: "benchmark.json",
    threshold: {
      terminalSize: { cols: 200, rows: 80 },
      phase: "combined",
      percentile: "p95Ms",
      maxMs: BENCHMARK_COMBINED_P95_LIMIT_MS,
      passed: thresholdPassed,
      actualMs,
    },
    sizes: results,
  };
  manifest.benchmark = benchmark;
  if (thresholdRequired && !thresholdPassed) {
    manifest.failures.push({
      invariant: "buffer-system-frame-bench-p95",
      frameIndex: 0,
      event: "benchmark",
      message:
        actualMs === null
          ? "missing 200x80 benchmark result"
          : `200x80 combined p95 ${actualMs.toFixed(3)}ms exceeds ${BENCHMARK_COMBINED_P95_LIMIT_MS}ms`,
    });
  }

  writeFileSync(join(artifactDir, benchmark.benchmarkPath), `${JSON.stringify(benchmark, null, 2)}\n`);
  writeFileSync(manifest.traceLogPath, "");
  writeFileSync(manifest.tapePath, "");
  writeFileSync(manifest.finalGridPath, "");
  writeFileSync(manifest.replaySummaryPath, `${JSON.stringify({ frame_count: 0, resize_count: 0, stdout_bytes: 0 }, null, 2)}\n`);
  writeRuntimeEvidence(manifest);
  manifest.completedAt = new Date().toISOString();
  writeManifest(manifest);
  writeReplayManifest(manifest);
  writeFailureFile(manifest);
  writeReproScript(manifest);
  writeReport(manifest);
  return manifest;
}

function runFrameBenchForSize(
  size: RenderLabTerminalSize,
  runs: number,
): RenderLabBenchmarkSizeResult {
  const samples: BenchSample[] = [];
  const warmups = Math.min(5, Math.max(1, Math.floor(runs / 4)));
  for (let i = 0; i < warmups; i += 1) {
    measureFrameBenchSample(size, -(warmups - i));
  }
  for (let i = 0; i < runs; i += 1) {
    samples.push(measureFrameBenchSample(size, i));
  }

  const invalidationReasons = [...new Set(samples.map((sample) => sample.invalidationReason))].sort();
  return {
    terminalSize: size,
    runs,
    invalidationReasons,
    changedCells: numericStats(samples.map((sample) => sample.changedCells)),
    diffBytes: numericStats(samples.map((sample) => sample.diffBytes)),
    fullRepaintCount: samples.filter((sample) => sample.fullRepaint).length,
    timings: {
      plan: timingStats(samples.map((sample) => sample.planMs)),
      surfaceInit: timingStats(samples.map((sample) => sample.surfaceInitMs)),
      paint: timingStats(samples.map((sample) => sample.paintMs)),
      validate: timingStats(samples.map((sample) => sample.validateMs)),
      diff: timingStats(samples.map((sample) => sample.diffMs)),
      combined: timingStats(samples.map((sample) => sample.combinedMs)),
    },
    allocations: {
      instrumentation: "unavailable",
      reason:
        "render-lab does not currently receive Zig allocator counters from the frame builder",
      phases: {
        plan: null,
        surfaceInit: null,
        paint: null,
        validate: null,
        diff: null,
      },
      oneTimeSetup: {
        estimatedCellSlots: size.cols * size.rows,
        estimatedBytes: size.cols * size.rows * 16,
      },
      hotFrame: {
        recurringRowsByColsAllocationMeasured: false,
        note:
          "hot-frame allocation counters are recorded as unavailable; timing samples still cover recurring frame work excluding terminal writer I/O",
      },
    },
  };
}

function measureFrameBenchSample(size: RenderLabTerminalSize, iteration: number): BenchSample {
  const planTimed = timed(() => buildBenchPlan(size, iteration));
  const previousTimed = timed(() => initBenchSurface(planTimed.value, iteration - 1));
  const surfaceTimed = timed(() => initBenchSurface(planTimed.value, iteration));
  const paintTimed = timed(() => paintBenchSurface(surfaceTimed.value, planTimed.value, iteration));
  const validateTimed = timed(() => validateBenchSurface(surfaceTimed.value, planTimed.value));
  const diffTimed = timed(() =>
    diffBenchSurface(previousTimed.value, surfaceTimed.value, planTimed.value),
  );
  void paintTimed.value;
  void validateTimed.value;

  return {
    planMs: planTimed.ms,
    surfaceInitMs: surfaceTimed.ms,
    paintMs: paintTimed.ms,
    validateMs: validateTimed.ms,
    diffMs: diffTimed.ms,
    combinedMs: planTimed.ms + paintTimed.ms + validateTimed.ms + diffTimed.ms,
    changedCells: diffTimed.value.changedCells,
    diffBytes: diffTimed.value.diffBytes,
    fullRepaint: planTimed.value.fullRepaint,
    invalidationReason: planTimed.value.invalidationReason,
  };
}

function buildBenchPlan(size: RenderLabTerminalSize, iteration: number): BenchPlan {
  const footerRows = 4;
  const activityRow = iteration % 5 === 0 ? Math.max(1, size.rows - footerRows - 1) : null;
  const footerTop = Math.max(1, size.rows - footerRows + 1);
  const transcriptBottom = Math.max(1, footerTop - (activityRow ? 2 : 1));
  const invalidationReason =
    iteration === 0 ? "resize" : iteration % 13 === 0 ? "external_clear" : "none";
  return {
    size,
    transcriptTop: 1,
    transcriptBottom,
    footerTop,
    footerBottom: size.rows,
    activityRow,
    invalidationReason,
    fullRepaint: invalidationReason !== "none",
    cursorRow: footerTop + 1,
    cursorCol: 3,
  };
}

function initBenchSurface(plan: BenchPlan, iteration: number): BenchSurface {
  const cells: BenchCell[] = new Array(plan.size.cols * plan.size.rows);
  for (let row = 1; row <= plan.size.rows; row += 1) {
    const owner = ownerForBenchRow(plan, row);
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const idx = benchIndex(plan.size, row, col);
      cells[idx] = {
        code: owner === "preserved_shell" ? 0x20 + ((row + col + iteration) % 4) : 0x20,
        owner,
        width: 1,
      };
    }
  }
  return {
    size: plan.size,
    cells,
    cursorRow: plan.cursorRow,
    cursorCol: plan.cursorCol,
  };
}

function paintBenchSurface(surface: BenchSurface, plan: BenchPlan, iteration: number): void {
  for (let row = plan.transcriptTop; row <= plan.transcriptBottom; row += 1) {
    const seed = row + iteration;
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const idx = benchIndex(plan.size, row, col);
      surface.cells[idx] = {
        code: 97 + ((seed + col) % 26),
        owner: "transcript",
        width: 1,
      };
    }
  }
  if (plan.activityRow) {
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const idx = benchIndex(plan.size, plan.activityRow, col);
      surface.cells[idx] = {
        code: col <= 12 ? "*".codePointAt(0)! : 0x20,
        owner: "activity",
        width: 1,
      };
    }
  }
  for (let row = plan.footerTop; row <= plan.footerBottom; row += 1) {
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const idx = benchIndex(plan.size, row, col);
      const divider = row === plan.footerTop || row === plan.footerBottom - 1;
      surface.cells[idx] = {
        code: divider ? 0x2500 : col === 1 ? ">".codePointAt(0)! : 0x20,
        owner: "footer",
        width: 1,
      };
    }
  }
}

function validateBenchSurface(surface: BenchSurface, plan: BenchPlan): void {
  if (surface.cells.length !== plan.size.cols * plan.size.rows) {
    throw new Error("invalid surface cell count");
  }
  if (
    surface.cursorRow < 1 ||
    surface.cursorRow > plan.size.rows ||
    surface.cursorCol < 1 ||
    surface.cursorCol > plan.size.cols
  ) {
    throw new Error("cursor out of bounds");
  }
  for (let row = 1; row <= plan.size.rows; row += 1) {
    const expected = ownerForBenchRow(plan, row);
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const cell = surface.cells[benchIndex(plan.size, row, col)]!;
      if (cell.width !== 1 || cell.owner !== expected) {
        throw new Error(`owner mismatch at ${row},${col}`);
      }
    }
  }
}

function diffBenchSurface(
  previous: BenchSurface,
  target: BenchSurface,
  plan: BenchPlan,
): { changedCells: number; diffBytes: number } {
  let changedCells = 0;
  let diffBytes = 0;
  const top = plan.transcriptTop;
  const bottom = plan.footerBottom;
  for (let row = top; row <= bottom; row += 1) {
    if (plan.fullRepaint) diffBytes += 8;
    for (let col = 1; col <= plan.size.cols; col += 1) {
      const idx = benchIndex(plan.size, row, col);
      const before = previous.cells[idx]!;
      const after = target.cells[idx]!;
      if (
        plan.fullRepaint ||
        before.code !== after.code ||
        before.owner !== after.owner ||
        before.width !== after.width
      ) {
        changedCells += 1;
        diffBytes += after.code > 0x7f ? 3 : 1;
      }
    }
  }
  return { changedCells, diffBytes };
}

function ownerForBenchRow(plan: BenchPlan, row: number): BenchCell["owner"] {
  if (plan.activityRow === row) return "activity";
  if (row >= plan.footerTop && row <= plan.footerBottom) return "footer";
  if (row >= plan.transcriptTop && row <= plan.transcriptBottom) return "transcript";
  return "preserved_shell";
}

function benchIndex(size: RenderLabTerminalSize, row: number, col: number): number {
  return (row - 1) * size.cols + (col - 1);
}

function timed<T>(fn: () => T): { value: T; ms: number } {
  const start = process.hrtime.bigint();
  const value = fn();
  const elapsed = Number(process.hrtime.bigint() - start) / 1_000_000;
  return { value, ms: elapsed };
}

function timingStats(values: number[]): RenderLabTimingStats {
  const sorted = sortedNumbers(values);
  return {
    samples: sorted.length,
    p50Ms: roundStat(percentile(sorted, 0.5)),
    p95Ms: roundStat(percentile(sorted, 0.95)),
    p99Ms: roundStat(percentile(sorted, 0.99)),
    minMs: roundStat(sorted[0] ?? 0),
    maxMs: roundStat(sorted.at(-1) ?? 0),
  };
}

function numericStats(values: number[]): RenderLabNumericStats {
  const sorted = sortedNumbers(values);
  return {
    samples: sorted.length,
    p50: Math.round(percentile(sorted, 0.5)),
    p95: Math.round(percentile(sorted, 0.95)),
    p99: Math.round(percentile(sorted, 0.99)),
    min: Math.round(sorted[0] ?? 0),
    max: Math.round(sorted.at(-1) ?? 0),
  };
}

function sortedNumbers(values: number[]): number[] {
  return [...values].sort((a, b) => a - b);
}

function percentile(sortedValues: number[], p: number): number {
  if (sortedValues.length === 0) return 0;
  const index = Math.min(
    sortedValues.length - 1,
    Math.max(0, Math.ceil(sortedValues.length * p) - 1),
  );
  return sortedValues[index]!;
}

function roundStat(value: number): number {
  return Math.round(value * 1000) / 1000;
}

async function launchFx(
  context: ScenarioContext,
  session: RenderLabTmux,
  label: string,
  options: FxLaunchOptions = {},
): Promise<void> {
  const environment = [
    options.gatewayApiKey ? `AI_GATEWAY_API_KEY=${shQuote(options.gatewayApiKey)}` : null,
    options.gatewayChatUrl ? `FX_E2E_GATEWAY_CHAT_URL=${shQuote(options.gatewayChatUrl)}` : null,
    options.gatewayModelsUrl ? `FX_E2E_GATEWAY_MODELS_URL=${shQuote(options.gatewayModelsUrl)}` : null,
    options.permissionMode ? `FX_PERMISSION_MODE=${shQuote(options.permissionMode)}` : null,
  ].filter((entry): entry is string => entry !== null).join(" ");
  const environmentPrefix = environment.length > 0 ? `${environment} ` : "";
  const stderrRedirect = options.stderrPath ? ` 2>${shQuote(options.stderrPath)}` : "";
  await session.sendText(
    `${environmentPrefix}FX_RECORD=${shQuote(context.manifest.tapePath)} FX_RECORD_INPUT=1 ${shQuote(FX_BIN)}${stderrRedirect}`,
  );
  await capture(context, session, `${label}-fx-launch-requested`);
  await session.waitForPane((pane) => pane.includes("Run /help for commands"), 25_000);
  await capture(context, session, `${label}-fx-prompt-visible`);
}

function startLocalGatewayFixture(expectedPromptTail: string): LocalGatewayFixture {
  const requests: string[] = [];
  let releaseResponseGate!: () => void;
  let responseReleased = false;
  const responseGate = new Promise<void>((resolve) => {
    releaseResponseGate = resolve;
  });
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push(`${request.method} ${url.pathname}`);

      if (request.method === "GET" && url.pathname === LOCAL_GATEWAY_MODELS_PATH) {
        return Response.json({
          data: [
            {
              id: "anthropic/claude-opus-4.7",
              type: "language",
              released: 1,
              tags: ["tool-use"],
            },
          ],
        });
      }

      if (request.method === "POST" && url.pathname === LOCAL_GATEWAY_CHAT_PATH) {
        const body = await request.text();
        if (!body.includes(expectedPromptTail)) {
          return new Response("prompt tail missing", { status: 422 });
        }
        await responseGate;
        const sse = [
          `data: ${JSON.stringify({ type: "text-delta", id: "render-lab", delta: LOCAL_GATEWAY_COMPLETION })}`,
          "",
          `data: ${JSON.stringify({
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 1 },
              outputTokens: { total: 1 },
            },
          })}`,
          "",
          "data: [DONE]",
          "",
        ].join("\n");
        return new Response(sse, {
          headers: {
            "content-type": "text/event-stream",
          },
        });
      }

      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    chatUrl: `${baseUrl}${LOCAL_GATEWAY_CHAT_PATH}`,
    modelsUrl: `${baseUrl}${LOCAL_GATEWAY_MODELS_PATH}`,
    requests,
    releaseResponse() {
      if (responseReleased) return;
      responseReleased = true;
      releaseResponseGate();
    },
    stop() {
      server.stop(true);
    },
  };
}

function startActiveToolGatewayFixture(): LocalGatewayFixture {
  const requests: string[] = [];
  let chatRequestCount = 0;
  let responseReleased = false;
  let releaseResponseGate!: () => void;
  const responseGate = new Promise<void>((resolve) => {
    releaseResponseGate = resolve;
  });
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === LOCAL_GATEWAY_MODELS_PATH) {
        requests.push(`${request.method} ${url.pathname}`);
        return Response.json({ data: [{ id: "anthropic/claude-opus-4.7", type: "language", released: 1, tags: ["tool-use"] }] });
      }
      if (request.method === "POST" && url.pathname === LOCAL_GATEWAY_CHAT_PATH) {
        const body = await request.text();
        if (body.includes("\"permission_decision\"")) {
          return permissionDecisionResponse();
        }
        requests.push(`${request.method} ${url.pathname}`);
        chatRequestCount += 1;
        if (chatRequestCount === 2) await responseGate;
        const sse = chatRequestCount === 1
          ? [
              `data: ${JSON.stringify({ type: "tool-input-start", id: "active_tool_1", toolName: "shell" })}`,
              "",
              `data: ${JSON.stringify({ type: "tool-call", toolCallId: "active_tool_1", toolName: "shell", input: { request: { action: "run", command: "sleep 1; i=1; sleep 3; while [ \"$i\" -le 32 ]; do printf 'ACTIVE_TOOL_LINE_%02d\\n' \"$i\"; i=$((i+1)); sleep 0.03; done; while [ ! -f .active-tool-release ]; do sleep 0.05; done", yield_time_ms: 30_000, timeout_ms: 600_000 } } })}`,
              "",
              `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } })}`,
              "",
              "data: [DONE]",
              "",
            ].join("\n")
          : [
              `data: ${JSON.stringify({ type: "text-delta", id: "render-lab", delta: LOCAL_GATEWAY_COMPLETION })}`,
              "",
              `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } })}`,
              "",
              "data: [DONE]",
              "",
            ].join("\n");
        return new Response(sse, { headers: { "content-type": "text/event-stream" } });
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    chatUrl: `${baseUrl}${LOCAL_GATEWAY_CHAT_PATH}`,
    modelsUrl: `${baseUrl}${LOCAL_GATEWAY_MODELS_PATH}`,
    requests,
    releaseResponse() {
      if (responseReleased) return;
      responseReleased = true;
      releaseResponseGate();
    },
    stop() { server.stop(true); },
  };
}

function startObservabilityGatewayFixture(
  expectedPromptTail: string,
): LocalGatewayFixture {
  const requests: string[] = [];
  let chatRequestCount = 0;
  let responseReleased = false;
  let releaseResponseGate!: () => void;
  const responseGate = new Promise<void>((resolve) => {
    releaseResponseGate = resolve;
  });
  const transcript = [
    OBSERVABILITY_TRANSCRIPT_HEAD,
    ...Array.from(
      { length: 28 },
      (_, index) =>
        `OBSERVABILITY_TRANSCRIPT_LINE_${String(index + 1).padStart(2, "0")}`,
    ),
    OBSERVABILITY_TRANSCRIPT_TAIL,
  ].join("\n");
  const command =
    `printf '\\117\\102\\123\\105\\122\\126\\101\\102\\111\\114\\111\\124\\131\\137\\124\\117\\117\\114\\137\\117\\125\\124\\120\\125\\124\\n'; ${OBSERVABILITY_TOOL_COMMAND}`;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === LOCAL_GATEWAY_MODELS_PATH) {
        requests.push(`${request.method} ${url.pathname}`);
        return Response.json({
          data: [
            {
              id: "anthropic/claude-opus-4.7",
              type: "language",
              released: 1,
              tags: ["tool-use"],
            },
          ],
        });
      }
      if (request.method === "POST" && url.pathname === LOCAL_GATEWAY_CHAT_PATH) {
        const body = await request.text();
        requests.push(`${request.method} ${url.pathname}`);
        chatRequestCount += 1;
        if (chatRequestCount === 1 && !body.includes(expectedPromptTail)) {
          return new Response("prompt tail missing", { status: 422 });
        }
        if (chatRequestCount === 2) await responseGate;
        const events = chatRequestCount === 1
          ? [
              {
                type: "text-delta",
                id: "observability-transcript",
                delta: transcript,
              },
              {
                type: "tool-input-start",
                id: "observability-tool-1",
                toolName: "shell",
              },
              {
                type: "tool-call",
                toolCallId: "observability-tool-1",
                toolName: "shell",
                input: {
                  request: { action: "run", command, timeout_ms: 600_000 },
                },
              },
              {
                type: "finish",
                finishReason: { unified: "tool-calls", raw: "tool-calls" },
                usage: {
                  inputTokens: { total: 1 },
                  outputTokens: { total: 1 },
                },
              },
            ]
          : [
              {
                type: "text-delta",
                id: "observability-final",
                delta: OBSERVABILITY_FINAL_MARKER,
              },
              {
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
                usage: {
                  inputTokens: { total: 1 },
                  outputTokens: { total: 1 },
                },
              },
            ];
        return gatewaySse(events);
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    chatUrl: `${baseUrl}${LOCAL_GATEWAY_CHAT_PATH}`,
    modelsUrl: `${baseUrl}${LOCAL_GATEWAY_MODELS_PATH}`,
    requests,
    releaseResponse() {
      if (responseReleased) return;
      responseReleased = true;
      releaseResponseGate();
    },
    stop() {
      server.stop(true);
    },
  };
}

function assertLocalGatewayRequests(requests: string[]): void {
  for (const expected of [`GET ${LOCAL_GATEWAY_MODELS_PATH}`, `POST ${LOCAL_GATEWAY_CHAT_PATH}`]) {
    if (!requests.includes(expected)) {
      throw new Error(`local gateway request missing: ${expected}\n${requests.join("\n")}`);
    }
  }
}

async function waitForLocalGatewayRequest(
  requests: string[],
  expected: string,
  timeoutMs: number,
): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (requests.includes(expected)) return;
    await sleep(25);
  }
  throw new Error(`timed out waiting for local gateway request: ${expected}\n${requests.join("\n")}`);
}

async function waitForLocalGatewayRequestCount(
  requests: string[],
  expected: string,
  count: number,
  timeoutMs: number,
): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (requests.filter((request) => request === expected).length >= count) return;
    await sleep(25);
  }
  throw new Error(
    `timed out waiting for ${count} local gateway requests: ${expected}\n${requests.join("\n")}`,
  );
}

async function submitSlashCommand(
  context: ScenarioContext,
  session: RenderLabTmux,
  command: string,
  expected: string,
  event: string,
): Promise<void> {
  await session.sendText(command);
  await session.waitForPane((pane) => pane.includes(expected), 10_000);
  await capture(context, session, event);
}

async function quitFx(context: ScenarioContext, session: RenderLabTmux, label: string): Promise<void> {
  await session.sendLiteral("/quit");
  await session.sendKeys("Enter");
  await session.sendKeys("Enter");
  await capture(context, session, `${label}-fx-quit-requested`);
  await session.waitForPane((pane) => pane.includes(PROMPT_TEXT), 15_000);
  await capture(context, session, `${label}-post-quit-shell-prompt`);
}

async function resize(
  context: ScenarioContext,
  session: RenderLabTmux,
  cols: number,
  rows: number,
  event: string,
): Promise<void> {
  await session.resize(cols, rows);
  await capture(context, session, event);
}

async function runShellCommand(
  context: ScenarioContext,
  session: RenderLabTmux,
  command: string,
  expected: string,
  event: string,
): Promise<void> {
  await session.sendText(command);
  await session.waitForPane((pane) => pane.includes(expected), 10_000);
  await capture(context, session, event);
}

async function capture(
  context: ScenarioContext,
  session: RenderLabTmux,
  event: string,
): Promise<RenderLabFrame> {
  const probe = await session.waitForStableVisibleState();
  const frame = attachFrameEvidence(
    session.captureFrame(
      context.manifest.frames.length + 1,
      event,
      context.binarySha256,
      context.manifest.traceLogPath,
    ),
    "tmux-pane",
    probe,
  );
  writeFrame(context.manifest, frame);
  writeManifest(context.manifest);
  return frame;
}

async function captureMatching(
  context: ScenarioContext,
  session: RenderLabTmux,
  event: string,
  predicate: (pane: string) => boolean,
  timeoutMs: number,
): Promise<RenderLabFrame> {
  const startedAt = Date.now();
  let lastGrid = "";
  while (Date.now() - startedAt < timeoutMs) {
    const remainingMs = timeoutMs - (Date.now() - startedAt);
    try {
      await session.waitForPane(predicate, Math.min(1_000, Math.max(250, remainingMs)));
    } catch {}

    const probe = await session.waitForStableVisibleState();
    const frame = attachFrameEvidence(
      session.captureFrame(
        context.manifest.frames.length + 1,
        event,
        context.binarySha256,
        context.manifest.traceLogPath,
      ),
      "tmux-pane",
      probe,
    );
    lastGrid = frame.grid.join("\n");
    if (probe.stable && predicate(lastGrid)) {
      writeFrame(context.manifest, frame);
      writeManifest(context.manifest);
      return frame;
    }
    await sleep(100);
  }

  throw new Error(`timed out waiting for stable captured frame: ${event}\n${lastGrid}`);
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

class RenderLabTmux {
  readonly name: string;
  readonly fixture: Fixture;
  private killed = false;

  private constructor(name: string, fixture: Fixture) {
    this.name = name;
    this.fixture = fixture;
  }

  static async create(opts: {
    fixture: Fixture;
    manifest: RenderLabManifest;
    width: number;
    height: number;
  }): Promise<RenderLabTmux> {
    const name = `fx-render-lab-${process.pid}-${randomBytes(4).toString("hex")}`;
    const env = testEnv(opts.fixture, opts.manifest);
    const command = [
      "env",
      "-u",
      "AI_GATEWAY_API_KEY",
      "-u",
      "VERCEL_OIDC_TOKEN",
      "FX_DISABLE_KEYCHAIN=1",
      "FX_SKIP_ONBOARDING=1",
      `HOME=${shQuote(opts.fixture.home)}`,
      `ZDOTDIR=${shQuote(opts.fixture.zdotdir)}`,
      `HISTFILE=${shQuote(opts.fixture.histfile)}`,
      `SHELL=${shQuote(zshPath())}`,
      `FX_TRACE_LOG=${shQuote(opts.manifest.traceLogPath)}`,
      `FX_TRACE_SCOPES=${shQuote(TRACE_SCOPES)}`,
      `SHELL_A_BEFORE_FIRST=${shQuote(opts.manifest.markers.shell[0] ?? "")}`,
      `SHELL_A_BETWEEN_LAUNCHES=${shQuote(opts.manifest.markers.shell[1] ?? "")}`,
      `SHELL_A_BEFORE_THIRD=${shQuote(opts.manifest.markers.shell[2] ?? "")}`,
      shQuote(zshPath()),
      // The fixture owns ZDOTDIR, so runner-global startup files must not run.
      "-d",
      "-i",
    ].join(" ");

    tmux(
      [
        "new-session",
        "-d",
        "-s",
        name,
        "-x",
        String(opts.width),
        "-y",
        String(opts.height),
        "-c",
        opts.fixture.work,
        command,
      ],
      env,
    );
    const session = new RenderLabTmux(name, opts.fixture);
    await sleep(800);
    await session.waitForPane((pane) => pane.includes(PROMPT_TEXT), 10_000);
    return session;
  }

  async sendText(text: string): Promise<void> {
    tmux(["send-keys", "-t", this.name, "-l", text]);
    await sleep(50);
    tmux(["send-keys", "-t", this.name, "Enter"]);
    await sleep(150);
  }

  async sendLiteral(text: string): Promise<void> {
    tmux(["send-keys", "-t", this.name, "-l", text]);
    await sleep(150);
  }

  async sendBracketedPaste(text: string): Promise<void> {
    const buffer = `${this.name}-paste`;
    tmux(["set-buffer", "-b", buffer, text]);
    try {
      tmux(["paste-buffer", "-p", "-b", buffer, "-t", this.name]);
    } finally {
      try {
        tmux(["delete-buffer", "-b", buffer]);
      } catch {}
    }
    await sleep(150);
  }

  async sendKeys(...keys: string[]): Promise<void> {
    tmux(["send-keys", "-t", this.name, ...keys]);
    await sleep(150);
  }

  async resize(cols: number, rows: number): Promise<void> {
    tmux(["resize-window", "-t", this.name, "-x", String(cols), "-y", String(rows)]);
    await sleep(450);
  }

  async waitForStableVisibleState() {
    return waitForStableProbe(() =>
      this.capturePane().split("\n").map((line) =>
        isVolatileTokenStatusRow(line) ? "<volatile-status>" : line
      ).join("\n")
    );
  }

  captureFrame(index: number, event: string, binarySha256: string, traceLogPath: string): RenderLabFrame {
    const size = this.paneSize();
    return {
      index,
      event,
      timestampMs: Date.now(),
      width: size.width,
      height: size.height,
      binaryPath: FX_BIN,
      binarySha256,
      grid: this.captureGrid(),
      escapes: this.captureEscapes(),
      scrollback: this.captureScrollback(),
      cursor: this.cursorPosition(),
      traceTail: traceTail(traceLogPath),
    };
  }

  async waitForPane(predicate: (pane: string) => boolean, timeoutMs: number): Promise<string> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const pane = this.capturePane();
      if (predicate(pane)) return pane;
      await sleep(250);
    }
    throw new Error(`timed out waiting for pane predicate\n${this.capturePane()}`);
  }

  async waitForEnd(timeoutMs: number): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (!this.isAlive()) return;
      await sleep(250);
    }
    throw new Error("tmux session did not exit");
  }

  async kill(): Promise<void> {
    if (this.killed) return;
    this.killed = true;
    try {
      tmux(["kill-session", "-t", this.name]);
    } catch {}
  }

  private capturePane(): string {
    try {
      return tmux(["capture-pane", "-t", this.name, "-p"]);
    } catch {
      return "";
    }
  }

  private captureGrid(): string[] {
    const raw = this.capturePane();
    if (raw.length === 0) return [];
    return raw.replace(/\n$/, "").split("\n");
  }

  private captureEscapes(): string {
    try {
      return tmux(["capture-pane", "-t", this.name, "-e", "-p", "-J"]);
    } catch {
      return "";
    }
  }

  private captureScrollback(): string {
    try {
      return tmux(["capture-pane", "-t", this.name, "-p", "-S", "-"]);
    } catch {
      return "";
    }
  }

  private paneSize(): { width: number; height: number } {
    const raw = tmux(["display-message", "-t", this.name, "-p", "#{pane_width}x#{pane_height}"]).trim();
    const [width, height] = raw.split("x").map((value) => Number.parseInt(value, 10));
    if (!Number.isFinite(width) || !Number.isFinite(height)) {
      throw new Error(`invalid tmux pane size: ${raw}`);
    }
    return { width: width!, height: height! };
  }

  private cursorPosition(): { row: number; col: number } | null {
    try {
      const raw = tmux(["display-message", "-t", this.name, "-p", "#{cursor_y} #{cursor_x}"]).trim();
      const [row, col] = raw.split(/\s+/).map((value) => Number.parseInt(value, 10));
      if (!Number.isFinite(row) || !Number.isFinite(col)) return null;
      return { row: row!, col: col! };
    } catch {
      return null;
    }
  }

  private isAlive(): boolean {
    try {
      tmux(["has-session", "-t", this.name]);
      return true;
    } catch {
      return false;
    }
  }
}

function preflight(): void {
  preflightBinaryOnly();
  tmux(["-V"]);
  zshPath();
}

function preflightBinaryOnly(): void {
  if (!existsSync(FX_BIN)) {
    throw new Error(`fx binary not found at ${FX_BIN}. Run zig build first.`);
  }
  const stat = statSync(FX_BIN);
  if (!stat.isFile() || (stat.mode & 0o111) === 0) {
    throw new Error(`fx binary is not executable at ${FX_BIN}`);
  }
}

function testEnv(fixture: Fixture, manifest: RenderLabManifest): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  delete env.AI_GATEWAY_API_KEY;
  delete env.VERCEL_OIDC_TOKEN;
  env.FX_DISABLE_KEYCHAIN = "1";
  env.FX_SKIP_ONBOARDING = "1";
  env.HOME = fixture.home;
  env.ZDOTDIR = fixture.zdotdir;
  env.HISTFILE = fixture.histfile;
  env.SHELL = zshPath();
  env.TERM_PROGRAM = "tmux";
  env.FX_TRACE_LOG = manifest.traceLogPath;
  env.FX_TRACE_SCOPES = TRACE_SCOPES;
  env.SHELL_A_BEFORE_FIRST = manifest.markers.shell[0] ?? "";
  env.SHELL_A_BETWEEN_LAUNCHES = manifest.markers.shell[1] ?? "";
  env.SHELL_A_BEFORE_THIRD = manifest.markers.shell[2] ?? "";
  return env;
}

function createFixture(runId: string): Fixture {
  const root = realpathSync(mkdtempSync(join(shortTempBase(), "fxrl-")));
  const fixture = {
    root,
    home: join(root, "h"),
    zdotdir: join(root, "z"),
    work: join(root, "w"),
    histfile: join(root, "hist"),
  };
  mkdirSync(join(fixture.home, ".fx"), { recursive: true });
  mkdirSync(fixture.zdotdir, { recursive: true });
  mkdirSync(fixture.work, { recursive: true });
  writeFileSync(
    join(fixture.home, ".fx", "settings.json"),
    `${JSON.stringify({})}\n`,
  );
  writeFileSync(join(fixture.work, "run-id.txt"), `${runId}\n`);
  writeFileSync(
    join(fixture.zdotdir, ".zshrc"),
    ["PROMPT='FX_RENDER_LAB%% '", "RPROMPT=''", "setopt NO_BEEP", ""].join("\n"),
  );
  return fixture;
}

function resolveRunDirs(path: string): string[] {
  const resolved = resolve(path);
  if (existsSync(join(resolved, "manifest.json"))) return [resolved];
  if (!existsSync(resolved)) return [];
  return readdirSync(resolved, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("run-"))
    .map((entry) => join(resolved, entry.name))
    .filter((dir) => existsSync(join(dir, "manifest.json")))
    .sort();
}

function readManifest(path: string): RenderLabManifest {
  return JSON.parse(readFileSync(path, "utf8")) as RenderLabManifest;
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

function writeReproScript(manifest: RenderLabManifest): void {
  const scenarioArgs = manifest.benchmark
    ? [
        "--scenario",
        manifest.scenario,
        "--runs",
        String(manifest.benchmark.sizes[0]?.runs ?? 1),
        "--sizes",
        manifest.benchmark.sizes
          .map((size) => `${size.terminalSize.cols}x${size.terminalSize.rows}`)
          .join(","),
      ]
    : ["--scenario", manifest.scenario, "--runs", "1"];
  const script = [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    `cd ${shQuote(join(REPO_ROOT, "tests", "e2e"))}`,
    `${shQuote(bunPath())} run render-lab -- ${scenarioArgs.map(shQuote).join(" ")} --out ${shQuote(dirname(manifest.artifactDir))}`,
    "",
  ].join("\n");
  writeFileSync(join(manifest.artifactDir, "repro.sh"), script, { mode: 0o755 });
}

function parseArgs(rawArgs: string[]): Partial<Options> {
  const args = rawArgs.filter((arg) => arg !== "--");
  const options: Partial<Options> = {};
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    switch (arg) {
      case "--scenario":
        options.scenario = requiredValue(args, ++i, arg);
        break;
      case "--runs":
        options.runs = Number.parseInt(requiredValue(args, ++i, arg), 10);
        break;
      case "--out":
        options.out = resolve(requiredValue(args, ++i, arg));
        break;
      case "--sizes":
        options.sizes = parseSizes(requiredValue(args, ++i, arg));
        break;
      case "--analyze":
        options.analyze = resolve(requiredValue(args, ++i, arg));
        break;
      case "--list-scenarios":
        options.listScenarios = true;
        break;
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  return options;
}

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) throw new Error(`${flag} requires a value`);
  return value;
}

function parseSizes(value: string): RenderLabTerminalSize[] {
  return value
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => {
      const match = /^(\d+)x(\d+)$/.exec(part);
      if (!match) throw new Error(`invalid --sizes entry: ${part}`);
      const cols = Number.parseInt(match[1]!, 10);
      const rows = Number.parseInt(match[2]!, 10);
      if (cols <= 0 || rows <= 0) throw new Error(`invalid --sizes entry: ${part}`);
      return { cols, rows };
    });
}

function printHelp(): void {
  console.log(
    [
      "usage: bun run render-lab -- [--scenario same-shell-relaunch] [--runs N] [--out PATH]",
      "       bun run render-lab -- --scenario buffer-system-frame-bench --runs N [--sizes 80x24,120x40,200x80] [--out PATH]",
      "       bun run render-lab -- --analyze PATH",
      "       bun run render-lab -- --list-scenarios",
      "",
      "default scenario:",
      `  ${SCENARIO}`,
      "",
      "benchmark scenarios:",
      `  ${BUFFER_SYSTEM_FRAME_BENCH}`,
      "",
      "startup scrollback scenarios:",
      `  ${STARTUP_SCROLLBACK_DISABLED_OVERFLOW}`,
      `  ${STARTUP_SCROLLBACK_ENABLED_OVERFLOW}`,
      "",
      "activity scenarios:",
      `  ${ACTIVE_TOOL_PLACEMENT}`,
      "",
      "user-card scenarios:",
      `  ${USER_CARD_RESIZE_REPLAY_SCROLLBACK}`,
      "",
      "observability scenarios:",
      `  ${TUI_OBSERVABILITY_GAUNTLET}`,
      "",
      ...nativeScenarioHelpLines(),
    ].join("\n"),
  );
}

function printScenarioList(): void {
  console.log(
    [
      "default scenario:",
      `  ${SCENARIO}`,
      "",
      "benchmark scenarios:",
      `  ${BUFFER_SYSTEM_FRAME_BENCH}`,
      "",
      "startup scrollback scenarios:",
      `  ${STARTUP_SCROLLBACK_DISABLED_OVERFLOW}`,
      `  ${STARTUP_SCROLLBACK_ENABLED_OVERFLOW}`,
      "",
      "activity scenarios:",
      `  ${ACTIVE_TOOL_PLACEMENT}`,
      "",
      "user-card scenarios:",
      `  ${USER_CARD_RESIZE_REPLAY_SCROLLBACK}`,
      "",
      "observability scenarios:",
      `  ${TUI_OBSERVABILITY_GAUNTLET}`,
      "",
      ...nativeScenarioHelpLines(),
    ].join("\n"),
  );
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

function longLine(runId: string, label: string): string {
  return Array.from({ length: 12 }, (_, index) => `shell-wrap-${runId}-${label}-${index}`).join("-");
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

async function waitForFileText(
  path: string,
  predicate: (text: string) => boolean,
  timeoutMs: number,
): Promise<string> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const text = readOptional(path);
    if (predicate(text)) return text;
    await sleep(250);
  }
  throw new Error(`timed out waiting for file predicate\n${readOptional(path)}`);
}

function readOptional(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function pad(value: number): string {
  return String(value).padStart(4, "0");
}

function tmux(args: string[], env?: NodeJS.ProcessEnv): string {
  return execFileSync("tmux", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: env ? { ...process.env, ...env } : process.env,
  });
}

function shQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

if (import.meta.main) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    process.exit(1);
  });
}
