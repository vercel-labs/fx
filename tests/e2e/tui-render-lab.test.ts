import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  analyzeRun,
  readQuiescence,
} from "./render-lab/analyzer";
import type { RenderLabFrame, RenderLabManifest } from "./render-lab/types";
import { tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 120_000;
let outDir: string | null = null;

afterEach(() => {
  if (!outDir) return;
  rmSync(outDir, { recursive: true, force: true });
  outDir = null;
});

test("render-lab lists gated Plan B native scenarios", () => {
  const output = execFileSync("bun", ["run", "render-lab", "--", "--list-scenarios"], {
    cwd: import.meta.dirname,
    encoding: "utf8",
  });

  expect(output).toContain("same-shell-relaunch");
  expect(output).toContain("buffer-system-frame-bench");
  expect(output).toContain("startup-scrollback-disabled-overflow");
  expect(output).toContain("startup-scrollback-enabled-overflow");
  expect(output).toContain("active-tool-placement");
  expect(output).toContain("user-card-resize-replay-scrollback");
  expect(output).toContain("tui-observability-gauntlet");
  expect(output).toContain("native-ghostty-relaunch");
  expect(output).toContain("native-terminal-app-relaunch");
  expect(output).toContain("native-terminal-app-command-k");
  expect(output).toContain("native-warp-relaunch");
  expect(output).toContain("FX_RENDER_LAB_NATIVE=1");
});

test.skipIf(!existsSync(FX_BIN))("buffer-system frame benchmark writes timing artifact", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-frame-bench-test-"));
  const output = execFileSync(
    "bun",
    [
      "run",
      "render-lab",
      "--",
      "--scenario",
      "buffer-system-frame-bench",
      "--runs",
      "20",
      "--sizes",
      "80x24,120x40,200x80",
      "--out",
      outDir,
    ],
    {
      cwd: import.meta.dirname,
      encoding: "utf8",
      timeout: 20_000,
    },
  );

  expect(output).toContain("buffer-system-frame-bench");
  const runDir = output.trim().split(/\s+/).at(-1)!;
  const benchmark = JSON.parse(readFileSync(join(runDir, "benchmark.json"), "utf8"));
  expect(benchmark.sizes[0].timings.combined.samples).toBe(20);
  expect(typeof benchmark.sizes[0].timings.plan.p50Ms).toBe("number");
  expect(typeof benchmark.sizes[0].timings.paint.p95Ms).toBe("number");
  expect(typeof benchmark.sizes[0].timings.validate.p99Ms).toBe("number");
  expect(typeof benchmark.sizes[0].timings.diff.p50Ms).toBe("number");
  expect(typeof benchmark.sizes[0].timings.combined.p95Ms).toBe("number");
  expect(benchmark.sizes[0].changedCells.p95).toBeGreaterThan(0);
  expect(benchmark.sizes[0].diffBytes.p95).toBeGreaterThan(0);
  expect(benchmark.sizes[0].allocations.instrumentation).toBe("unavailable");
});

test.skipIf(!existsSync(FX_BIN))("buffer-system p95 gate rejects undersampled runs", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-frame-bench-samples-test-"));
  const result = spawnSync(
    "bun",
    [
      "run",
      "render-lab",
      "--",
      "--scenario",
      "buffer-system-frame-bench",
      "--runs",
      "3",
      "--sizes",
      "200x80",
      "--out",
      outDir,
    ],
    {
      cwd: import.meta.dirname,
      encoding: "utf8",
      timeout: 20_000,
    },
  );

  expect(result.status).toBe(1);
  expect(result.stderr).toContain("p95 threshold requires at least 20 runs");
});

test("native render-lab scenarios require explicit opt-in", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-gate-test-"));
  const env = { ...process.env };
  delete env.FX_RENDER_LAB_NATIVE;
  delete env.FX_RENDER_LAB_NATIVE_COMMAND_K;
  delete env.FX_RENDER_LAB_NATIVE_ALLOW_CLIPBOARD;

  const result = spawnSync(
    "bun",
    [
      "run",
      "render-lab",
      "--",
      "--scenario",
      "native-terminal-app-command-k",
      "--runs",
      "1",
      "--out",
      outDir,
    ],
    {
      cwd: import.meta.dirname,
      env,
      encoding: "utf8",
      timeout: 20_000,
    },
  );

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("FX_RENDER_LAB_NATIVE=1");
});

test("render-lab analyzer flags excess gap before transient activity", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "content",
    "",
    "thinking",
    "",
    "",
    "────────────────",
    ">",
    "────────────────",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("activity-footer-extra-blank");
});

test("render-lab analyzer treats thinking token counters as activity rows", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "content",
    "",
    "thinking (↑10 ↓20)",
    "",
    "",
    "────────────────",
    ">",
    "────────────────",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("activity-footer-extra-blank");
});

test("render-lab analyzer recognizes the real fx prompt glyph", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "❯",
    "────────────────",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).not.toContain("footer-missing");
  expect(failures).not.toContain("input-missing");
});

test("render-lab analyzer recognizes tint footer chrome", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "❯",
    "────────────────",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).not.toContain("footer-missing");
  expect(failures).not.toContain("input-missing");
});

test("render-lab analyzer flags missing footer and input chrome", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "permission_mode",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("footer-missing");
  expect(failures).toContain("input-missing");
});

test("render-lab analyzer rejects damaged multiline footer with real hint and cursor", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "  transcript row one",
    "  transcript row two",
    "────────────────",
    "run fx login · opus 4.7 · default",
  ], { row: 3, col: 8 });

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("footer-missing");
  expect(failures).toContain("input-missing");
});

test("render-lab analyzer recognizes clipped multiline input continuation rows", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "  wrapped input continuation",
    "  clipped input tail",
    "────────────────",
    "run fx login · opus 4.7 · default",
  ], { row: 3, col: 20 }, ["clipped input tail"], "overflow-long-prompt-editor-tail-visible");

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).not.toContain("footer-missing");
  expect(failures).not.toContain("input-missing");
});

test("render-lab analyzer recognizes compact multiline footer status", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "  wrapped input continuation",
    "  clipped input tail",
    "────────────────",
    "opus 4.7 · default",
  ], { row: 3, col: 20 }, ["clipped input tail"], "overflow-long-prompt-editor-tail-visible");

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).not.toContain("footer-missing");
  expect(failures).not.toContain("input-missing");
});

test("render-lab analyzer rejects a blank multiline footer status row", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "  wrapped input continuation",
    "  clipped input tail",
    "────────────────",
    "",
  ], { row: 3, col: 20 }, ["clipped input tail"], "overflow-long-prompt-editor-tail-visible");

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("footer-missing");
  expect(failures).toContain("input-missing");
});

test("render-lab analyzer flags missing required gap before thinking", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "content",
    "thinking",
    "────────────────",
    ">",
    "────────────────",
    "model",
  ]);

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("activity-leading-gap-missing");
});

test("render-lab analyzer fails when the trace log is missing", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "content",
    "",
    "thinking",
    "────────────────",
    ">",
    "────────────────",
    "model",
  ]);
  manifest.traceLogPath = join(outDir, "missing-trace.log");

  const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);

  expect(failures).toContain("trace-present");
});

test("render-lab analyzer enforces active-tool placement and uniqueness", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const cases = [
    {
      event: "active-tool-visible",
      grid: ["Run /help for commands", "", "● Running sleep 1; i=1", "  sleep 0.03; done; sleep 4", "", "▲ Thinking", "", "────────────────", "❯", "────────────────", "test"],
      rejected: false,
    },
    {
      event: "active-tool-clipped",
      grid: ["│ ACTIVE_TOOL_LINE_05", "│ … 27 lines more (ctrl o to view)", "", "● Running sleep 1; i=1", "", "▲ Thinking", "", "────────────────", "❯", "────────────────", "test"],
      rejected: false,
    },
    {
      event: "active-tool-clipped",
      grid: ["│ ACTIVE_TOOL_LINE_05", "│ … 27 lines more (ctrl o to view)", "", "▲ Thinking", "", "────────────────", "❯", "────────────────", "test"],
      rejected: true,
    },
    {
      event: "active-tool-visible",
      grid: ["Run /help for commands", "● Running sleep 1; i=1", "● Running sleep 1; i=1", "", "────────────────", "❯", "────────────────", "test"],
      rejected: true,
    },
  ];
  for (const [index, entry] of cases.entries()) {
    const manifest = writeAnalyzerFixture(
      join(outDir, String(index)),
      entry.grid,
      null,
      [],
      entry.event,
    );
    configureActiveToolManifest(manifest);
    const failures = analyzeRun(manifest).failures.map((failure) => failure.invariant);
    expect(failures.includes("active-tool-marker-count")).toBe(entry.rejected);
    if (!entry.rejected) expect(failures).not.toContain("active-tool-placement");
  }
});

test("render-lab analyzer rejects activity marker corruption", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const submitted = "exercise one active command placement";
  const group = "● 1 tool call · 1 command";
  const activity = "└ Running sleep 1; i=1";
  const cases = [
    {
      name: "missing",
      lines: [`┃ ${submitted}`, "", group],
      invariant: "active-tool-activity-marker-count",
    },
    {
      name: "duplicate",
      lines: [`┃ ${submitted}`, "", group, activity, activity],
      invariant: "active-tool-activity-marker-count",
    },
    {
      name: "reordered",
      lines: [group, activity, "", `┃ ${submitted}`],
      invariant: "active-tool-activity-marker-order",
    },
    {
      name: "blank",
      lines: [`┃ ${submitted}`, "", "", group, activity],
      invariant: "active-tool-activity-blank-hole",
    },
  ];
  for (const entry of cases) {
    const grid = [
      "Run /help for commands",
      "",
      group,
      activity,
      "",
      "• Thinking",
      "",
      "┃",
      "",
      "auto · test",
    ];
    const manifest = writeAnalyzerFixture(
      join(outDir, entry.name),
      grid,
      null,
      [submitted],
      "active-tool-visible",
      entry.lines.join("\n"),
    );
    configureActiveToolManifest(manifest);
    const failures = analyzeRun(manifest).failures.map(
      (failure) => failure.invariant,
    );
    expect(failures).toContain(entry.invariant);
  }
});

test("render-lab analyzer rejects expanded command marker corruption", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const commandLines = Array.from(
    { length: 32 },
    (_, index) => `│ ACTIVE_TOOL_LINE_${String(index + 1).padStart(2, "0")}`,
  );
  const cases = [
    {
      name: "missing",
      lines: commandLines.filter((line) => !line.includes("LINE_16")),
      invariant: "active-tool-command-marker-count",
    },
    {
      name: "duplicate",
      lines: [...commandLines, commandLines[15]!],
      invariant: "active-tool-command-marker-count",
    },
    {
      name: "reordered",
      lines: [
        ...commandLines.slice(0, 14),
        commandLines[15]!,
        commandLines[14]!,
        ...commandLines.slice(16),
      ],
      invariant: "active-tool-command-marker-order",
    },
    {
      name: "blank",
      lines: [
        ...commandLines.slice(0, 16),
        "",
        ...commandLines.slice(16),
      ],
      invariant: "active-tool-command-blank-hole",
    },
  ];
  for (const entry of cases) {
    const grid = [
      "● Ran sleep 1; i=1",
      "────────────────",
      "❯",
      "────────────────",
      "test",
    ];
    const manifest = writeAnalyzerFixture(
      join(outDir, entry.name),
      [...grid.slice(0, 1), "│ ACTIVE_TOOL_LINE_32", ...grid.slice(1)],
      null,
      [],
      "active-tool-command-output-expanded",
      ["● Ran sleep 1; i=1", ...entry.lines].join("\n"),
    );
    configureActiveToolManifest(manifest);
    const failures = analyzeRun(manifest).failures.map(
      (failure) => failure.invariant,
    );
    expect(failures).toContain(entry.invariant);
  }
});

test("render-lab analyzer rejects duplicate permission UI", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const prompt = "Would you like to run the following command?";
  for (const [name, prompts, rejected] of [
    ["single", [prompt], false],
    ["duplicate", [prompt, prompt], true],
  ] as const) {
    const manifest = writeAnalyzerFixture(
      join(outDir, name),
      [
        "OBSERVABILITY_TRANSCRIPT_HEAD",
        "OBSERVABILITY_TRANSCRIPT_TAIL",
        ...prompts,
        "1. Yes",
      ],
      null,
      [],
      "observability-permission-inline",
    );
    manifest.scenario = "tui-observability-gauntlet";

    const failures = analyzeRun(manifest).failures.map(
      (failure) => failure.invariant,
    );

    expect(failures.includes("observability-permission-singleton")).toBe(
      rejected,
    );
  }
});

test("render-lab analyzer rejects reordered observability scrollback", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const markers = ["OBSERVABILITY_PROMPT_HEAD", "OBSERVABILITY_PROMPT_TAIL"];
  for (const [name, transcript, rejected] of [
    [
      "ordered",
      ["OBSERVABILITY_TRANSCRIPT_HEAD", "OBSERVABILITY_TRANSCRIPT_TAIL"],
      false,
    ],
    [
      "reordered",
      ["OBSERVABILITY_TRANSCRIPT_TAIL", "OBSERVABILITY_TRANSCRIPT_HEAD"],
      true,
    ],
  ] as const) {
    const scrollback = [
      ...markers,
      ...transcript,
      "OBSERVABILITY_TOOL_OUTPUT",
      "OBSERVABILITY_FINAL_RESPONSE",
    ].join("\n");
    const manifest = writeAnalyzerFixture(
      join(outDir, name),
      [
        "OBSERVABILITY_FINAL_RESPONSE",
        "────────────────",
        "❯",
        "────────────────",
        "model",
      ],
      null,
      markers,
      "observability-final-restored",
      scrollback,
    );
    manifest.scenario = "tui-observability-gauntlet";

    const failures = analyzeRun(manifest).failures.map(
      (failure) => failure.invariant,
    );

    expect(failures.includes("observability-scrollback-order")).toBe(rejected);
  }
});

test("render-lab analyzer reports trace counters and rejects quiescent work", () => {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-analyzer-test-"));
  const manifest = writeAnalyzerFixture(outDir, [
    "Run /help for commands",
    "────────────────",
    "❯",
    "────────────────",
    "model",
  ]);
  writeFileSync(
    manifest.traceLogPath,
    [
      "0 [frame_plan] build layout=80x24 transcript=1..19 footer=20..24 activity=0..0 invalidations=1 body=transcript captured=false",
      "0 [frame_commit] wire_frame bytes=42 accepted_bytes=42 applied_scroll_rows=0 cleanup=none",
      "0 [frame_diff] result state=committed bytes=42 changed_cells=3 full_repaint=true invalidation=reserved_gap_clear next_invalidations=0",
    ].join("\n"),
  );
  writeFileSync(
    join(manifest.artifactDir, "quiescence.json"),
    `${JSON.stringify([{
      event: "synthetic-stable",
      durationMs: 300,
      before: {
        frameAttempts: 1,
        terminalDiffs: 1,
        terminalWrites: 1,
        invalidations: 0,
        invalidationReasons: {},
      },
      after: {
        frameAttempts: 2,
        terminalDiffs: 2,
        terminalWrites: 1,
        invalidations: 0,
        invalidationReasons: {},
      },
      delta: {
        frameAttempts: 1,
        terminalDiffs: 1,
        terminalWrites: 0,
        invalidations: 0,
        invalidationReasons: {},
      },
    }], null, 2)}\n`,
  );

  const analysis = analyzeRun(manifest);
  expect(analysis.traceCounters).toMatchObject({
    frameAttempts: 1,
    terminalDiffs: 1,
    terminalWrites: 1,
    invalidations: 1,
    invalidationReasons: { reserved_gap_clear: 1 },
  });
  expect(analysis.failures.map((failure) => failure.invariant))
    .toContain("quiescent-frame-work");
});

describe.skipIf(SKIP)("tui: render lab", () => {
  test(
    "active tool placement keeps one visible marker across resize states",
    () => {
      const artifacts = runScenarioArtifacts("active-tool-placement");
      const manifest = artifacts.manifest;
      expect(manifest.failures).toEqual([]);
      const quiescence = readQuiescence(manifest);
      expect(quiescence).toHaveLength(1);
      expect(quiescence[0]?.durationMs).toBeGreaterThan(50);
      expect(quiescence[0]?.delta).toEqual({
        frameAttempts: 0,
        terminalDiffs: 0,
        terminalWrites: 0,
        invalidations: 0,
        invalidationReasons: {},
      });

      const activityTrace = artifacts.trace
        .split(/\r?\n/)
        .filter((line) => line.includes("[ui_activity]"))
        .join("\n");
      expect(activityTrace).not.toContain("active_tool_1");
      expect(activityTrace).not.toContain("ACTIVE_TOOL_LINE");
      expect(activityTrace).not.toContain("exercise one active command placement");
    },
    TIMEOUT,
  );

  test(
    "same-shell relaunch artifacts pass analyzer without an API key",
    () => {
      outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-test-"));
      const env = { ...process.env };
      delete env.AI_GATEWAY_API_KEY;
      delete env.VERCEL_OIDC_TOKEN;

      const output = execFileSync(
        "bun",
        [
          "run",
          "render-lab",
          "--",
          "--scenario",
          "same-shell-relaunch",
          "--runs",
          "1",
          "--out",
          outDir,
        ],
        {
          cwd: import.meta.dirname,
          env,
          encoding: "utf8",
          timeout: TIMEOUT,
        },
      );

      expect(output).toContain("same-shell-relaunch");
      expect(output).toContain("run-");
      expect(FX_BIN).toContain("zig-out/bin/fx");
      const runDir = output.trim().split(/\s+/).at(-1)!;
      const manifest = JSON.parse(readFileSync(join(runDir, "manifest.json"), "utf8"));
      const replay = JSON.parse(readFileSync(join(runDir, "replay-summary.json"), "utf8"));
      const finalGrid = readFileSync(join(runDir, "final-grid.txt"), "utf8");
      const runtimeEvidence = JSON.parse(readFileSync(join(runDir, "runtime-evidence.json"), "utf8"));
      expect(manifest.failures).toEqual([]);
      expect(replay.frame_count).toBeGreaterThan(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);
      expect(finalGrid.length).toBeGreaterThan(0);
      expect(runtimeEvidence.frames.every((frame: { evidence: { stable: boolean } | null }) => frame.evidence?.stable)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "user card resize replay keeps one card and one startup banner in scrollback",
    () => {
      const artifacts = runScenarioArtifacts("user-card-resize-replay-scrollback");
      expect(artifacts.manifest.failures).toEqual([]);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "user-card-resized-narrow")).toBe(true);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "user-card-resized-wide")).toBe(true);
      for (const marker of artifacts.manifest.markers.submitted) {
        expect(artifacts.finalFrame.grid.join("\n")).toContain(marker);
      }
      const resizeFrames = artifacts.frames.filter((frame) =>
        frame.event === "user-card-resized-narrow" ||
        frame.event === "user-card-resized-wide"
      );
      for (const frame of resizeFrames) {
        for (const marker of [
          ...(artifacts.manifest.markers.history ?? []),
          ...artifacts.manifest.markers.submitted,
        ]) {
          expect(frame.scrollback.split(marker).length - 1).toBe(1);
        }
      }
      expect(readQuiescence(artifacts.manifest)).toHaveLength(1);
      expect(artifacts.gatewayRequests).toEqual([
        "GET /coding-agent/v1/models",
        "POST /v3/ai/language-model",
      ]);
      expect(artifacts.stderr).toBe("");
    },
    TIMEOUT,
  );

  test(
    "startup scrollback disabled overflow artifacts pass tape oracle",
    () => {
      const artifacts = runScenarioArtifacts("startup-scrollback-disabled-overflow");
      expect(artifacts.manifest.failures).toEqual([]);
      expect(artifacts.trace).toMatch(/\[scroll\] preserved_row_release .*accepted=[1-9]\d* .*owned_top=1(?:\s|$)/);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "overflow-long-prompt-editor-tail-visible")).toBe(true);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "overflow-submitted-prompt-tail-visible")).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => row.includes(artifacts.manifest.markers.submitted[0]!))).toBe(true);
      expect(artifacts.manifest.markers.history?.every((marker) => artifacts.finalFrame.scrollback.includes(marker))).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => /^┃\s*$/.test(row))).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => row.includes("HTTP 401"))).toBe(false);
      expect(artifacts.finalFrame.grid.some((row) => row.includes("RENDER_LAB_LOCAL_GATEWAY_OK"))).toBe(false);
      expect(artifacts.gatewayRequests).toEqual(["GET /coding-agent/v1/models", "POST /v3/ai/language-model"]);
      expect(artifacts.stderr).toBe("");
    },
    TIMEOUT,
  );

  test(
    "startup scrollback enabled overflow starts eagerly without progressive release",
    () => {
      const artifacts = runScenarioArtifacts("startup-scrollback-enabled-overflow");
      expect(artifacts.manifest.failures).toEqual([]);
      expect(artifacts.trace).toMatch(/\[frame_layout\] fixed_point .*prior_owned_top=1 post_scroll_owned_top=1/);
      expect(artifacts.trace).not.toMatch(/\[scroll\] preserved_row_release .*accepted=[1-9]\d*/);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "overflow-long-prompt-editor-tail-visible")).toBe(true);
      expect(artifacts.manifest.frames.some((frame) => frame.event === "overflow-submitted-prompt-tail-visible")).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => row.includes(artifacts.manifest.markers.submitted[0]!))).toBe(true);
      expect(artifacts.manifest.markers.history?.every((marker) => artifacts.finalFrame.scrollback.includes(marker))).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => /^┃\s*$/.test(row))).toBe(true);
      expect(artifacts.finalFrame.grid.some((row) => row.includes("HTTP 401"))).toBe(false);
      expect(artifacts.finalFrame.grid.some((row) => row.includes("RENDER_LAB_LOCAL_GATEWAY_OK"))).toBe(false);
      expect(artifacts.gatewayRequests).toEqual(["GET /coding-agent/v1/models", "POST /v3/ai/language-model"]);
      expect(artifacts.stderr).toBe("");
    },
    TIMEOUT,
  );
});

function runScenarioArtifacts(scenario: string): {
  manifest: RenderLabManifest;
  frames: RenderLabFrame[];
  finalFrame: RenderLabFrame;
  trace: string;
  stderr: string;
  gatewayRequests: string[];
} {
  outDir = mkdtempSync(join(tmpdir(), "fx-render-lab-overflow-test-"));
  const env = { ...process.env };
  delete env.AI_GATEWAY_API_KEY;
  delete env.VERCEL_OIDC_TOKEN;
  const output = execFileSync(
    "bun",
    ["run", "render-lab", "--", "--scenario", scenario, "--runs", "1", "--out", outDir],
    {
      cwd: import.meta.dirname,
      env,
      encoding: "utf8",
      timeout: TIMEOUT,
    },
  );
  const runDir = output.trim().split(/\s+/).at(-1)!;
  const manifest = JSON.parse(readFileSync(join(runDir, "manifest.json"), "utf8")) as RenderLabManifest;
  const finalFrame = manifest.frames.find((frame) => frame.index === manifest.finalFrameIndex) ?? manifest.frames.at(-1)!;
  const frames = manifest.frames.map((frame) =>
    JSON.parse(readFileSync(join(runDir, frame.jsonPath), "utf8")) as RenderLabFrame
  );
  return {
    manifest,
    frames,
    finalFrame: JSON.parse(readFileSync(join(runDir, finalFrame.jsonPath), "utf8")) as RenderLabFrame,
    trace: readFileSync(join(runDir, "trace.log"), "utf8"),
    stderr: readFileSync(join(runDir, "stderr.log"), "utf8"),
    gatewayRequests: readFileSync(join(runDir, "gateway-requests.log"), "utf8").trim().split("\n"),
  };
}

function writeAnalyzerFixture(
  artifactDir: string,
  grid: string[],
  cursor: RenderLabFrame["cursor"] = null,
  submittedMarkers: string[] = [],
  event = "synthetic",
  scrollback = grid.join("\n"),
): RenderLabManifest {
  mkdirSync(artifactDir, { recursive: true });
  const frame: RenderLabFrame = {
    index: 1,
    event,
    timestampMs: 0,
    width: 80,
    height: grid.length,
    binaryPath: FX_BIN,
    binarySha256: "test",
    grid,
    escapes: "",
    scrollback,
    cursor,
    traceTail: [],
  };
  writeFileSync(join(artifactDir, "frame-1.json"), `${JSON.stringify(frame, null, 2)}\n`);
  writeFileSync(join(artifactDir, "trace.log"), "[frame_diff] result state=committed bytes=1 changed_cells=1 full_repaint=false invalidation=none\n");

  return {
    version: 1,
    scenario: "synthetic",
    runId: "test",
    startedAt: "2026-05-10T00:00:00.000Z",
    completedAt: null,
    repoRoot: import.meta.dirname,
    artifactDir,
    binaryPath: FX_BIN,
    binarySha256: "test",
    traceLogPath: join(artifactDir, "trace.log"),
    tapePath: join(artifactDir, "render.fxtape"),
    finalGridPath: join(artifactDir, "final-grid.txt"),
    replaySummaryPath: join(artifactDir, "replay-summary.json"),
    runtimeEvidencePath: join(artifactDir, "runtime-evidence.json"),
    reportPath: join(artifactDir, "report.html"),
    failurePath: join(artifactDir, "failures.md"),
    finalFrameIndex: 1,
    evidence: {
      oracle: "synthetic",
      capturePolicy: "synthetic",
      screenshotPolicy: "none",
      maxSettleMs: 0,
      stableSamples: 0,
    },
    markers: {
      shell: [],
      submitted: submittedMarkers,
    },
    frames: [
      {
        index: 1,
        event,
        timestampMs: 0,
        width: 80,
        height: grid.length,
        gridPath: "frame-1.grid.txt",
        jsonPath: "frame-1.json",
      },
    ],
    failures: [],
  };
}

function configureActiveToolManifest(manifest: RenderLabManifest): void {
  manifest.scenario = "active-tool-placement";
}
