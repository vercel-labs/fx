import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { platform, tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const REAL_TITLE = "RESUME_REAL_SESSION_FIRST_PROMPT";
const FOREIGN_TITLE = "RESUME_FOREIGN_NEWEST";
const FINAL_MARKER = "RESUME_REAL_SESSION_HISTORY_DONE";

type Config = {
  label: string;
  catalogEntries: number;
  chatBatches: number;
  chatLinesPerBatch: number;
  toolsPerBatch: number;
  cycles: number;
  profileSeconds?: number;
  retainArtifacts?: boolean;
};

type Metrics = {
  open: number[];
  scope: number[];
  page: number[];
  resize: number[];
  close: number[];
  resume: number[];
  rssKib: number[];
  threads: number[];
  fileDescriptors: number[];
};

type Paths = {
  root: string;
  home: string;
  workspace: string;
  foreignWorkspace: string;
  stderr: string;
  trace: string;
  metrics: string;
  profile: string;
};

type IndexedSummary = {
  id: string;
  created_at_ms: number;
  updated_at_ms: number;
  workspace_root: string | null;
  origin_workspace_root?: string | null;
  conversation_language: string;
  history_len: number;
  has_managed_children?: boolean;
  display_metadata_present?: boolean;
  title?: string | null;
  preview?: string | null;
};

function pad(value: number, width = 6): string {
  return String(value).padStart(width, "0");
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

function percentile(values: number[], fraction: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
}

function summarize(values: number[]) {
  const result: Record<string, number> = {
    count: values.length,
    p50Ms: Number(percentile(values, 0.5).toFixed(3)),
    p95Ms: Number(percentile(values, 0.95).toFixed(3)),
    maxMs: Number(Math.max(0, ...values).toFixed(3)),
  };
  if (values.length >= 100) {
    result.p99Ms = Number(percentile(values, 0.99).toFixed(3));
  }
  return result;
}

function makePaths(label: string): Paths {
  const tempRoot = platform() === "darwin" ? "/private/tmp" : tmpdir();
  const root = realpathSync(mkdtempSync(join(tempRoot, `fx-r-${label}-`)));
  return {
    root,
    home: join(root, "home"),
    workspace: join(root, "workspace"),
    foreignWorkspace: join(root, "foreign-workspace"),
    stderr: join(root, "stderr.log"),
    trace: join(root, "resume-trace.log"),
    metrics: join(root, "resume-metrics.json"),
    profile: join(root, "resume.sample.txt"),
  };
}

function gatewayEnv(home: string, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-resume-brutal-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function prepareFilesystem(paths: Paths, config: Config): void {
  mkdirSync(join(paths.home, ".fx"), { recursive: true });
  mkdirSync(paths.workspace);
  mkdirSync(paths.foreignWorkspace);
  writeFileSync(paths.stderr, "");
  writeFileSync(paths.trace, "");
  writeFileSync(
    join(paths.home, ".fx", "settings.json"),
    JSON.stringify({
      sandbox: "none",
      permission_mode: "auto",
      permission: {},
      max_agent_steps: config.chatBatches + 12,
      max_tool_result_bytes: 2 * 1024 * 1024,
    }),
  );
  const toolLines = Array.from(
    { length: 800 },
    (_, index) =>
      `RESUME_TOOL_PAYLOAD_${pad(index)} ${"wide-tool-output-".repeat(8)} ` +
      `${index % 3 === 0 ? "界" : index % 3 === 1 ? "e\u0301" : "👩‍💻"}`,
  );
  writeFileSync(
    join(paths.workspace, "resume-tool-payload.txt"),
    `${toolLines.join("\n")}\n`,
  );
}

function historyBatch(batch: number, config: Config): Response {
  const lines = Array.from(
    { length: config.chatLinesPerBatch },
    (_, line) => {
      const global = batch * config.chatLinesPerBatch + line;
      const marker = `RESUME_CHAT_${pad(global)}`;
      switch (global % 6) {
        case 0:
          return `${marker} real conversation prose ${"wrap-".repeat(10)}界`;
        case 1:
          return `${marker} \`\`\`zig const value_${global} = ${global}; \`\`\``;
        case 2:
          return `${marker} | row | status | ✅ |`;
        case 3:
          return `${marker} {"nested":{"ok":true,"n":${global}}}`;
        case 4:
          return `${marker} - [x] completed real-world task`;
        default:
          return `${marker} multilingual مرحبا 日本語 e\u0301 👩‍💻`;
      }
    },
  ).join("\n");
  const events: object[] = [{
    type: "text-delta",
    id: `resume-answer-${batch}`,
    delta: `${lines}\n`,
  }];
  for (let tool = 0; tool < config.toolsPerBatch; tool += 1) {
    events.push({
      type: "tool-call",
      toolCallId: `resume-tool-${batch}-${tool}`,
      toolName: "read_file",
      input: {
        path: "resume-tool-payload.txt",
        line_start: (tool * 73) % 600,
        line_count: 200,
      },
    });
  }
  events.push({
    type: "finish",
    finishReason: { unified: "tool-calls", raw: "tool-calls" },
  });
  return fakeGatewaySse(events);
}

async function seedRealSession(paths: Paths, config: Config): Promise<IndexedSummary> {
  const responses: Response[] = [];
  for (let batch = 0; batch < config.chatBatches; batch += 1) {
    responses.push(historyBatch(batch, config));
  }
  responses.push(fakeGatewayFinalText(FINAL_MARKER));
  const gateway = startFakeGateway(responses);
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: realpathSync(paths.workspace),
      env: gatewayEnv(paths.home, gateway),
      stderrPath: paths.stderr,
      width: 104,
      height: 30,
      minimumHistoryLines: Math.max(
        20_000,
        config.chatBatches * config.chatLinesPerBatch * 2,
      ),
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText(`${REAL_TITLE}: build the prepared long chat and tool history.`);
    await session.waitForText(FINAL_MARKER, TIMEOUT * 20);
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT * 2)).toBe(true);
  } finally {
    if (session) await session.kill();
    gateway.stop();
  }

  const indexPath = join(paths.home, ".fx", "sessions", "index.json");
  const parsed = JSON.parse(readFileSync(indexPath, "utf8")) as {
    sessions: IndexedSummary[];
  };
  expect(parsed.sessions).toHaveLength(1);
  const actual = parsed.sessions[0]!;
  actual.title = REAL_TITLE;
  actual.preview = `${REAL_TITLE}\n50K chat and large tools`;
  actual.display_metadata_present = true;
  return actual;
}

function installLargeCatalog(
  paths: Paths,
  config: Config,
  real: IndexedSummary,
): void {
  const sessionsRoot = join(paths.home, ".fx", "sessions");
  const base = Math.max(Date.now(), real.updated_at_ms + config.catalogEntries + 10);
  const entries: IndexedSummary[] = [];
  entries.push({
    id: "resume-foreign-newest",
    created_at_ms: base,
    updated_at_ms: base,
    workspace_root: realpathSync(paths.foreignWorkspace),
    conversation_language: "ja",
    history_len: 50_000,
    display_metadata_present: true,
    title: FOREIGN_TITLE,
  });
  entries.push({
    ...real,
    updated_at_ms: base - 1,
    workspace_root: realpathSync(paths.workspace),
    // The stress conversation is one very large user turn spanning many
    // tool continuations. Its projection can lag the committed event tail,
    // but the catalog row must remain resumable while that tail is replayed.
    history_len: Math.max(1, real.history_len),
  });
  for (let index = 2; index < config.catalogEntries; index += 1) {
    const foreign = index % 4 === 0;
    entries.push({
      id: `resume-stress-${pad(index)}`,
      created_at_ms: base - index,
      updated_at_ms: base - index,
      workspace_root: foreign
        ? realpathSync(paths.foreignWorkspace)
        : realpathSync(paths.workspace),
      conversation_language: index % 5 === 0 ? "ar" : index % 3 === 0 ? "ja" : "en",
      history_len: 1 + (index % 50_000),
      display_metadata_present: true,
      title: index % 101 === 0 ? `S${pad(index)} 界` : `S${pad(index)}`,
    });
  }
  const indexPath = join(sessionsRoot, "index.json");
  writeFileSync(indexPath, JSON.stringify({ schema_version: 3, sessions: entries }));
  chmodSync(indexPath, 0o600);
  const bytes = statSync(indexPath).size;
  expect(bytes).toBeLessThanOrEqual(16 * 1024 * 1024);
}

function menuCount(text: string): number {
  const match = stripAnsi(text).match(/Sessions (\d+)/);
  return match ? Number(match[1]) : 0;
}

async function waitForMenu(
  session: TmuxSession,
  marker: string,
  scope: "Current workspace" | "All workspaces",
): Promise<string> {
  const visibleMarker = marker.slice(-7);
  return session.waitForPane((pane) => {
    const plain = stripAnsi(pane);
    return plain.includes(visibleMarker) && plain.includes(`[${scope}]`) && menuCount(plain) > 0;
  }, TIMEOUT * 4);
}

async function time(
  values: number[],
  action: () => Promise<void>,
  visible: () => Promise<unknown>,
): Promise<void> {
  const started = performance.now();
  await action();
  await visible();
  values.push(performance.now() - started);
}

function processStats(pid: number): { rssKib: number; threads: number; fileDescriptors: number } {
  const rssKib = Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)], {
    encoding: "utf8",
  }).trim());
  const threads = platform() === "darwin"
    ? execFileSync("ps", ["-M", "-p", String(pid)], { encoding: "utf8" })
      .trim().split("\n").length - 1
    : readdirSync(`/proc/${pid}/task`).length;
  const fileDescriptors = platform() === "darwin"
    ? execFileSync("/usr/sbin/lsof", ["-p", String(pid)], { encoding: "utf8" })
      .trim().split("\n").length - 1
    : readdirSync(`/proc/${pid}/fd`).length;
  return { rssKib, threads, fileDescriptors };
}

async function loadNextPage(session: TmuxSession, metrics: Metrics): Promise<void> {
  const before = menuCount(await session.capturePane());
  await time(
    metrics.page,
    () => session.sendKeys(
      Array.from({ length: before + 1 }, () => "Down").join(" "),
    ),
    () => session.waitForPane((pane) => menuCount(pane) > before, TIMEOUT * 4),
  );
}

async function thrash(
  session: TmuxSession,
  config: Config,
  metrics: Metrics,
  pid: number,
): Promise<void> {
  const sizes = [
    [60, 12],
    [160, 44],
    [80, 24],
    [112, 32],
  ] as const;
  for (let cycle = 0; cycle < config.cycles; cycle += 1) {
    await time(
      metrics.open,
      () => session.sendText("/resume"),
      () => waitForMenu(session, REAL_TITLE, "Current workspace"),
    );
    await time(
      metrics.scope,
      () => session.sendKeys("Tab"),
      () => waitForMenu(session, FOREIGN_TITLE, "All workspaces"),
    );
    await time(
      metrics.scope,
      () => session.sendKeys("Tab"),
      () => waitForMenu(session, REAL_TITLE, "Current workspace"),
    );
    if (cycle % 4 === 0) await loadNextPage(session, metrics);

    const [width, height] = sizes[cycle % sizes.length]!;
    await time(
      metrics.resize,
      () => session.resizeWindow(width, height),
      () => session.waitForPane((pane) => stripAnsi(pane).includes("[Current workspace]"), TIMEOUT),
    );
    await time(
      metrics.close,
      () => session.sendKeys("Escape"),
      () => session.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return hasEmptyComposer(plain) &&
          !plain.includes("[Current workspace]") &&
          !plain.includes("[All workspaces]");
      }, TIMEOUT),
    );
    expect(session.paneStatus().dead).toBe(false);
    const stats = processStats(pid);
    metrics.rssKib.push(stats.rssKib);
    metrics.threads.push(stats.threads);
    metrics.fileDescriptors.push(stats.fileDescriptors);
  }
}

async function runStress(config: Config): Promise<Paths> {
  const paths = makePaths(config.label);
  prepareFilesystem(paths, config);
  const real = await seedRealSession(paths, config);
  installLargeCatalog(paths, config, real);
  writeFileSync(paths.stderr, "");

  const gateway = startFakeGateway([]);
  const metrics: Metrics = {
    open: [],
    scope: [],
    page: [],
    resize: [],
    close: [],
    resume: [],
    rssKib: [],
    threads: [],
    fileDescriptors: [],
  };
  let session: TmuxSession | null = null;
  let profiler: ReturnType<typeof Bun.spawn> | null = null;
  let passed = false;
  try {
    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: realpathSync(paths.workspace),
      env: {
        ...gatewayEnv(paths.home, gateway),
        FX_TRACE_LOG: paths.trace,
        FX_TRACE_SCOPES: "core,session",
      },
      stderrPath: paths.stderr,
      width: 112,
      height: 32,
      minimumHistoryLines: Math.max(
        50_000,
        config.chatBatches * config.chatLinesPerBatch * 2,
      ),
    });
    await session.waitForComposer(TIMEOUT * 4);
    const pid = session.processPid();
    const initial = processStats(pid);
    metrics.rssKib.push(initial.rssKib);
    metrics.threads.push(initial.threads);
    metrics.fileDescriptors.push(initial.fileDescriptors);

    if (config.profileSeconds !== undefined) {
      profiler = Bun.spawn([
        "/usr/bin/sample",
        String(pid),
        String(config.profileSeconds),
        "1",
        "-mayDie",
        "-file",
        paths.profile,
      ], { stdout: "pipe", stderr: "pipe" });
    }

    await thrash(session, config, metrics, pid);

    await session.sendText("/resume");
    await waitForMenu(session, REAL_TITLE, "Current workspace");
    await time(
      metrics.resume,
      () => session!.sendKeys("Enter"),
      () => session!.waitForText(FINAL_MARKER, TIMEOUT * 20),
    );
    expect(await session.captureFullScrollback()).toContain("RESUME_CHAT_000000");
    expect(await session.captureFullScrollback()).toContain(
      `RESUME_CHAT_${pad(config.chatBatches * config.chatLinesPerBatch - 1)}`,
    );
    expect(await session.captureFullScrollback()).toContain("resume-tool-payload.txt");

    if (profiler) await profiler.exited;
    expect(readFileSync(paths.stderr, "utf8")).toBe("");
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT * 2)).toBe(true);

    const report = {
      config,
      catalogBytes: statSync(join(paths.home, ".fx", "sessions", "index.json")).size,
      transitions: {
        open: summarize(metrics.open),
        scope: summarize(metrics.scope),
        page: summarize(metrics.page),
        resize: summarize(metrics.resize),
        close: summarize(metrics.close),
        resume: summarize(metrics.resume),
      },
      firstOpenMs: Number(metrics.open[0]!.toFixed(3)),
      samples: metrics,
      resources: {
        startRssKib: metrics.rssKib[0],
        endRssKib: metrics.rssKib.at(-1),
        peakRssKib: Math.max(...metrics.rssKib),
        growthRssKib: metrics.rssKib.at(-1)! - metrics.rssKib[0]!,
        startThreads: metrics.threads[0],
        peakThreads: Math.max(...metrics.threads),
        endThreads: metrics.threads.at(-1),
        startFileDescriptors: metrics.fileDescriptors[0],
        peakFileDescriptors: Math.max(...metrics.fileDescriptors),
        endFileDescriptors: metrics.fileDescriptors.at(-1),
      },
    };
    writeFileSync(paths.metrics, `${JSON.stringify(report, null, 2)}\n`);

    // These are local regression alarms, not product-level latency contracts.
    expect(report.transitions.open.p95Ms).toBeLessThan(2_000);
    expect(report.transitions.scope.p95Ms).toBeLessThan(2_000);
    expect(report.transitions.page.p95Ms).toBeLessThan(5_000);
    expect(report.transitions.close.p95Ms).toBeLessThan(2_000);
    expect(report.resources.growthRssKib).toBeLessThan(256 * 1024);
    expect(report.resources.peakThreads - report.resources.startThreads).toBeLessThan(8);
    expect(
      report.resources.peakFileDescriptors - report.resources.startFileDescriptors,
    ).toBeLessThan(16);
    if (config.profileSeconds !== undefined) {
      expect(existsSync(paths.profile)).toBe(true);
      const sample = readFileSync(paths.profile, "utf8");
      expect(sample).toContain("Analysis of sampling");
      expect(sample).not.toContain("Failed to sample process");
    }

    passed = true;
    return paths;
  } finally {
    if (profiler) {
      try {
        profiler.kill();
      } catch {}
    }
    if (session) await session.kill();
    gateway.stop();
    if (config.retainArtifacts || config.profileSeconds !== undefined || !passed) {
      console.error(`retained resume stress artifacts at ${paths.root}`);
    } else {
      rmSync(paths.root, { recursive: true, force: true });
    }
  }
}

test.skipIf(!tmuxAvailable())(
  "/resume survives repeated real-chat, tool, scope, pagination, resize, and reopen thrashing",
  async () => {
    await runStress({
      label: "ci-soak",
      catalogEntries: 2_000,
      chatBatches: 2,
      chatLinesPerBatch: 500,
      toolsPerBatch: 4,
      cycles: 12,
    });
  },
  300_000,
);

test.skipIf(!tmuxAvailable() || process.env.FX_RESUME_BRUTAL !== "1")(
  "/resume sustains one hundred mixed interaction cycles without resource drift",
  async () => {
    await runStress({
      label: "extended-soak",
      catalogEntries: 10_000,
      chatBatches: 8,
      chatLinesPerBatch: 500,
      toolsPerBatch: 4,
      cycles: 100,
      retainArtifacts: true,
    });
  },
  900_000,
);

test.skipIf(
  !tmuxAvailable() ||
    process.env.FX_RESUME_PROFILE !== "1" ||
    platform() !== "darwin" ||
    !existsSync("/usr/bin/sample"),
)(
  "/resume native profiler captures sustained menu thrashing",
  async () => {
    const paths = await runStress({
      label: "profile",
      catalogEntries: 10_000,
      chatBatches: 6,
      chatLinesPerBatch: 500,
      toolsPerBatch: 4,
      cycles: 40,
      profileSeconds: 15,
      retainArtifacts: true,
    });
    console.error(`RESUME_PROFILE_METRICS=${paths.metrics}`);
    console.error(`RESUME_PROFILE_SAMPLE=${paths.profile}`);
  },
  900_000,
);

test.skipIf(!tmuxAvailable() || process.env.FX_RESUME_50K !== "1")(
  "/resume survives a fifty-thousand-entry catalog and real fifty-thousand-line tool-heavy session",
  async () => {
    const profileSeconds = process.env.FX_RESUME_PROFILE === "1" &&
        platform() === "darwin" &&
        existsSync("/usr/bin/sample")
      ? 30
      : undefined;
    const paths = await runStress({
      label: "real-50k",
      catalogEntries: 50_000,
      chatBatches: 50,
      chatLinesPerBatch: 1_000,
      toolsPerBatch: 4,
      cycles: 120,
      profileSeconds,
      retainArtifacts: true,
    });
    console.error(`RESUME_50K_METRICS=${paths.metrics}`);
    if (profileSeconds !== undefined) {
      console.error(`RESUME_50K_SAMPLE=${paths.profile}`);
    }
  },
  1_800_000,
);
