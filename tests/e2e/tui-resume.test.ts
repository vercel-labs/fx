import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySerializedToolCall,
  fakeGatewaySse,
  fakeGatewayToolCall,
  hasEmptyComposer,
  isEmptyComposerLine,
  isVolatileTokenStatusRow,
  paneExitMatches,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { readTapeFrames } from "./render-lab/tape";

const TIMEOUT = 30_000;
const UPGRADE_TIMEOUT = TIMEOUT * 2;
const SESSION_PICKER_META_RE = /\bturns?\b/;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";

function sessionIdFromHome(home: string): string {
  const sessions = join(home, ".fx", "sessions");
  const ids = readdirSync(sessions, { withFileTypes: true })
    .filter((entry) => entry.name !== "latest" && entry.isDirectory())
    .map((entry) => entry.name);
  expect(ids).toHaveLength(1);
  return ids[0]!;
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function startUpgradeServer(
  root: string,
  argvLogPath: string,
): { baseUrl: string; stop: () => void } {
  const artifactDir = join(root, "release-artifact");
  const wrapperPath = join(artifactDir, "fx");
  const archivePath = join(root, "fx.tar.gz");
  mkdirSync(artifactDir);
  const script = `#!/bin/sh
{
  printf '%s' "$0"
  for arg in "$@"; do
    printf '\\t%s' "$arg"
  done
  printf '\\n'
} >> ${shellQuote(argvLogPath)}
exec ${shellQuote(FX_BIN)} "$@"
`;
  writeFileSync(wrapperPath, script);
  chmodSync(wrapperPath, 0o755);
  const tar = Bun.spawnSync(["tar", "-czf", archivePath, "-C", artifactDir, "fx"]);
  if (tar.exitCode !== 0) throw new Error(tar.stderr.toString());

  const archive = readFileSync(archivePath);
  const checksum = createHash("sha256").update(archive).digest("hex");
  const platform = `${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
  const archiveRoute = `/v9.9.9/fx-${platform}.tar.gz`;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/latest.txt") return new Response("v9.9.9\n");
      if (path === archiveRoute) return new Response(archive);
      if (path === `${archiveRoute}.sha256`) return new Response(`${checksum}\n`);
      return new Response("not found", { status: 404 });
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    stop: () => server.stop(true),
  };
}

function gatewayEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-tui-resume-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

async function waitForScrollback(
  session: TmuxSession,
  marker: string,
  timeout = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeout;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.captureFullScrollback();
    if (latest.includes(marker)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for ${marker}.\nScrollback:\n${latest}`);
}

async function waitForScrollbackMarkers(
  session: TmuxSession,
  markers: readonly string[],
  timeout = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeout;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.captureFullScrollback();
    if (markers.every((marker) => latest.includes(marker))) return latest;
    await Bun.sleep(100);
  }
  throw new Error(
    `Timed out waiting for scrollback markers ${markers.join(", ")}.\nScrollback:\n${latest}`,
  );
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

async function waitForScrollbackOccurrences(
  session: TmuxSession,
  marker: string,
  expectedCount: number,
  timeout = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeout;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.captureFullScrollback();
    if (countOccurrences(latest, marker) >= expectedCount) return latest;
    await Bun.sleep(100);
  }
  throw new Error(
    `Timed out waiting for ${expectedCount} occurrences of ${marker}.\nScrollback:\n${latest}`,
  );
}

type HoldState = {
  started: boolean;
  cancelled: boolean;
};

function heldGatewayResponse(state: HoldState): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        controller.enqueue(
          encoder.encode(
            `data: ${JSON.stringify({ type: "text-delta", id: "held", delta: "SESSION_PICKER_ACTIVE_STREAM" })}\n\n`,
          ),
        );
        timer = setInterval(() => {
          controller.enqueue(encoder.encode(": keep-alive\n\n"));
        }, 100);
      },
      cancel() {
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function streamedTextResponse(text: string): Response {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream<Uint8Array>({
      async start(controller) {
        for (let offset = 0; offset < text.length; offset += 24) {
          const delta = text.slice(offset, offset + 24);
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta })}\n\n`,
            ),
          );
          await Bun.sleep(10);
        }
        controller.enqueue(
          encoder.encode(
            `data: ${JSON.stringify({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: {
                inputTokens: { total: 3 },
                outputTokens: { total: 5 },
              },
            })}\n\ndata: [DONE]\n\n`,
          ),
        );
        controller.close();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function waitForCondition(
  predicate: () => boolean,
  description: string,
  timeout = TIMEOUT,
): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

async function waitForPersistedSessionMarker(
  home: string,
  marker: string,
  timeout = TIMEOUT,
): Promise<void> {
  const sessionsDir = join(home, ".fx", "sessions");
  await waitForCondition(() => {
    if (!existsSync(sessionsDir)) return false;
    return readdirSync(sessionsDir, { withFileTypes: true })
      .filter((entry) => entry.name !== "latest" && entry.isDirectory())
      .some((entry) => {
        const eventsPath = join(sessionsDir, entry.name, "events.jsonl");
        return existsSync(eventsPath) &&
          readFileSync(eventsPath, "utf8").includes(marker);
      });
  }, `persisted session marker ${marker}`, timeout);
}

async function waitForCommittedSessionMarker(
  home: string,
  marker: string,
  timeout = TIMEOUT,
): Promise<void> {
  const sessionsDir = join(home, ".fx", "sessions");
  await waitForCondition(() => {
    if (!existsSync(sessionsDir)) return false;
    return readdirSync(sessionsDir, { withFileTypes: true })
      .filter((entry) => entry.name !== "latest" && entry.isDirectory())
      .some((entry) => {
        const sessionDir = join(sessionsDir, entry.name);
        const eventsPath = join(sessionDir, "events.jsonl");
        if (!existsSync(eventsPath) || !readFileSync(eventsPath, "utf8").includes(marker)) {
          return false;
        }
        const watermarkName = readdirSync(sessionDir).find(
          (name) => name.startsWith("commit.") && name.endsWith(".json"),
        );
        if (!watermarkName) return false;
        try {
          const watermark = JSON.parse(
            readFileSync(join(sessionDir, watermarkName), "utf8"),
          ) as { through_event_log_bytes?: number };
          return watermark.through_event_log_bytes === statSync(eventsPath).size;
        } catch {
          return false;
        }
      });
  }, `committed session marker ${marker}`, timeout);
}

async function waitForSessionPicker(session: TmuxSession): Promise<string> {
  return session.waitForPane(
    (pane) => {
      const plain = stripAnsi(pane);
      return plain.includes("Sessions") && SESSION_PICKER_META_RE.test(plain);
    },
    TIMEOUT,
  );
}

async function waitForSessionPickerClosed(session: TmuxSession): Promise<string> {
  return session.waitForPane(
    (pane) => {
      const plain = stripAnsi(pane);
      return hasEmptyComposer(plain) &&
        !plain.includes("Sessions");
    },
    TIMEOUT,
  );
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

type SessionPickerEntry = {
  row: number;
  title: string;
  meta: string;
  selected: boolean;
};

function visibleSessionPickerEntries(escapes: string): SessionPickerEntry[] {
  const rawLines = escapes.split("\n");
  const lines = rawLines.map(stripAnsi);
  const entries: SessionPickerEntry[] = [];
  for (let index = 0; index < lines.length - 1; index += 1) {
    const title = lines[index]!;
    const meta = title;
    if (!SESSION_PICKER_META_RE.test(meta) || !meta.includes(" · ")) continue;
    const trimmedTitle = title.trimStart();
    if (
      trimmedTitle.length === 0 ||
      trimmedTitle.startsWith("Sessions") ||
      trimmedTitle.startsWith("Tab ")
    ) {
      continue;
    }
    entries.push({
      row: index,
      title,
      meta,
      selected: rawLines[index]!.includes(SELECTED_COMPLETION_SGR),
    });
  }
  return entries;
}

const TAG_FLAG_SYMBOL = "\ud83c\udff4\udb40\udc67\udb40\udc62\udb40\udc65\udb40\udc6e\udb40\udc67\udb40\udc7f";

const SEMANTIC_TABLE_ROWS = [
  { type: "ASCII", symbol: "OK", description: "Plain ASCII", cells: 2 },
  { type: "Emoji", symbol: "\u2705", description: "Passed", cells: 2 },
  { type: "Emoji", symbol: "\u274c", description: "Failed", cells: 2 },
  { type: "CJK", symbol: "\u754c", description: "Wide character", cells: 2 },
  { type: "VS15", symbol: "\u2600\ufe0e", description: "Text presentation", cells: 1 },
  { type: "Wide VS15", symbol: "\u231a\ufe0e", description: "Wide text presentation", cells: 2 },
  { type: "VS16", symbol: "\u2600\ufe0f", description: "Emoji presentation", cells: 2 },
  { type: "Modifier", symbol: "\ud83d\udc4d\ud83c\udffd", description: "Skin tone", cells: 2 },
  { type: "Flag", symbol: "\ud83c\uddfa\ud83c\uddf8", description: "Regional pair", cells: 2 },
  { type: "Keycap", symbol: "#\ufe0f\u20e3", description: "Keycap sequence", cells: 2 },
  {
    type: "Tag",
    symbol: TAG_FLAG_SYMBOL,
    description: "RGI tag flag",
    cells: 2,
  },
  { type: "ZWJ", symbol: "\ud83d\udc69\u200d\ud83d\udcbb", description: "Joined sequence", cells: 2 },
] as const;

type SemanticObservation = "tmux" | "replay";
type SemanticRow = (typeof SEMANTIC_TABLE_ROWS)[number];

function isLossyLinuxTmuxSymbolRow(
  row: SemanticRow,
  observation: SemanticObservation,
  platform = process.platform,
): boolean {
  return observation === "tmux" && platform === "linux" &&
    (row.type === "Keycap" || row.type === "Tag" || row.type === "ZWJ");
}

function hasUnstableLinuxTmuxColumns(
  row: SemanticRow,
  observation: SemanticObservation,
  platform = process.platform,
): boolean {
  return observation === "tmux" && platform === "linux" && row.type !== "ASCII";
}

function hasSemanticSymbol(
  text: string,
  row: SemanticRow,
  observation: SemanticObservation,
  platform = process.platform,
): boolean {
  if (text.includes(row.symbol)) return true;
  if (!isLossyLinuxTmuxSymbolRow(row, observation, platform)) return false;
  if (row.type === "Keycap") return /#\ufe0f(?: +\u20e3)?/u.test(text);
  if (row.type === "Tag") return text.includes("\ud83c\udff4");
  return text.includes("\ud83d\udc69");
}

function expectSemanticTableRows(
  text: string,
  observation: SemanticObservation,
): void {
  for (const row of SEMANTIC_TABLE_ROWS) {
    expect(text).toContain(row.type);
    expect(text).toContain(row.description);
    expect(hasSemanticSymbol(text, row, observation)).toBe(true);
  }
  expect(text).not.toContain("| Type | Symbol | Description |");
}

function physicalBorderColumns(line: string): number[] {
  let normalized = line;
  for (const row of SEMANTIC_TABLE_ROWS) {
    normalized = normalized.replaceAll(row.symbol, " ".repeat(row.cells));
  }
  return [...normalized.matchAll(/│/g)].map((match) =>
    Bun.stringWidth(normalized.slice(0, match.index))
  );
}

function semanticColumnsMatch(
  row: SemanticRow,
  expected: number[],
  captured: number[],
  observation: SemanticObservation,
  platform = process.platform,
): boolean {
  const exact = captured.length === expected.length &&
    captured.every((column, index) => column === expected[index]);
  if (exact) return true;
  if (!hasUnstableLinuxTmuxColumns(row, observation, platform)) return false;
  const hasEnoughBorders = isLossyLinuxTmuxSymbolRow(row, observation, platform)
    ? captured.length >= 2
    : captured.length === expected.length;
  return hasEnoughBorders && captured[0] === expected[0] &&
    captured.every((column, index) => index === 0 || column > captured[index - 1]!);
}

function expectAlignedSemanticTable(
  scrollback: string,
  observation: SemanticObservation,
): void {
  const lines = scrollback.split("\n").map(stripAnsi);
  const header = lines.find((line) =>
    line.includes("Type") && line.includes("Symbol") && line.includes("Description")
  );
  expect(header).toBeDefined();
  const expectedColumns = physicalBorderColumns(header!);
  expect(expectedColumns).toHaveLength(4);

  for (const row of SEMANTIC_TABLE_ROWS) {
    const line = lines.find((candidate) => candidate.includes(row.description));
    expect(line).toBeDefined();
    expect(hasSemanticSymbol(line!, row, observation)).toBe(true);
    const capturedColumns = physicalBorderColumns(line!);
    expect(semanticColumnsMatch(
      row,
      expectedColumns,
      capturedColumns,
      observation,
    )).toBe(true);
  }
}

function findPaginatedSemanticFieldLines(
  lines: string[],
  row: SemanticRow,
  observation: SemanticObservation,
): { symbolLine: string | undefined; descriptionLine: string | undefined } {
  const symbolLine = lines.find((line) =>
    line.includes("│Symbol:") && hasSemanticSymbol(line, row, observation)
  );
  const descriptionLine = lines.find((line) =>
    line.includes("│Description:") && line.includes(row.description)
  );
  return { symbolLine, descriptionLine };
}

function expectAlignedSemanticCards(
  text: string,
  observation: SemanticObservation,
): void {
  const lines = text.split("\n").map(stripAnsi);
  let expectedColumns: number[] | undefined;

  for (const row of SEMANTIC_TABLE_ROWS) {
    const { symbolLine, descriptionLine } = findPaginatedSemanticFieldLines(
      lines,
      row,
      observation,
    );
    expect(symbolLine).toBeDefined();
    expect(descriptionLine).toBeDefined();
    expect(hasSemanticSymbol(symbolLine!, row, observation)).toBe(true);

    const symbolColumns = physicalBorderColumns(symbolLine!);
    const descriptionColumns = physicalBorderColumns(descriptionLine!);
    expect(symbolColumns).toHaveLength(2);
    expect(descriptionColumns).toHaveLength(2);
    expect(semanticColumnsMatch(
      row,
      descriptionColumns,
      symbolColumns,
      observation,
    )).toBe(true);
    if (expectedColumns) {
      expect(descriptionColumns).toEqual(expectedColumns);
    } else {
      expectedColumns = descriptionColumns;
    }
  }
}

test("Linux tmux fallbacks preserve exact ASCII and replay alignment", () => {
  const keycap = SEMANTIC_TABLE_ROWS.find((row) => row.type === "Keycap")!;
  const tag = SEMANTIC_TABLE_ROWS.find((row) => row.type === "Tag")!;
  const zwj = SEMANTIC_TABLE_ROWS.find((row) => row.type === "ZWJ")!;
  const cjk = SEMANTIC_TABLE_ROWS.find((row) => row.type === "CJK")!;
  const ascii = SEMANTIC_TABLE_ROWS.find((row) => row.type === "ASCII")!;
  const partialTagFlag = "\ud83c\udff4\udb40\udc67\udb40\udc62\udb40\udc65\udb40\udc6e";
  expect(hasSemanticSymbol("#\ufe0f", keycap, "tmux", "linux")).toBe(true);
  expect(hasSemanticSymbol("#\ufe0f", keycap, "replay", "linux")).toBe(false);
  expect(hasSemanticSymbol(partialTagFlag, tag, "tmux", "linux")).toBe(true);
  expect(hasSemanticSymbol("\ud83d\udc69", zwj, "tmux", "linux")).toBe(true);
  expect(hasSemanticSymbol("", tag, "tmux", "linux")).toBe(false);
  expect(hasSemanticSymbol("", zwj, "tmux", "linux")).toBe(false);
  expect(hasSemanticSymbol(partialTagFlag, tag, "replay", "linux")).toBe(false);
  expect(hasSemanticSymbol("\ud83d\udc69", zwj, "replay", "linux")).toBe(false);
  expect(hasSemanticSymbol(TAG_FLAG_SYMBOL, tag, "replay", "linux")).toBe(true);

  const aligned = [2, 14, 23, 48];
  const linuxPlaceholder = [2, 14, 20, 45];
  const linuxWrappedPlaceholder = [2, 14];
  const linuxShiftedPlaceholder = [2, 11, 20, 45];
  const linuxBorderlessPlaceholder: number[] = [];
  expect(semanticColumnsMatch(
    keycap,
    aligned,
    linuxPlaceholder,
    "tmux",
    "linux",
  )).toBe(true);
  expect(semanticColumnsMatch(
    tag,
    aligned,
    linuxWrappedPlaceholder,
    "tmux",
    "linux",
  )).toBe(true);
  expect(semanticColumnsMatch(
    zwj,
    aligned,
    linuxShiftedPlaceholder,
    "tmux",
    "linux",
  )).toBe(true);
  expect(semanticColumnsMatch(
    cjk,
    aligned,
    linuxPlaceholder,
    "tmux",
    "linux",
  )).toBe(true);
  expect(semanticColumnsMatch(
    cjk,
    aligned,
    linuxWrappedPlaceholder,
    "tmux",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    cjk,
    aligned,
    [2, 8, 14, 20, 45],
    "tmux",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    cjk,
    aligned,
    linuxPlaceholder,
    "replay",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    zwj,
    aligned,
    linuxBorderlessPlaceholder,
    "tmux",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    zwj,
    aligned,
    [3, 14],
    "tmux",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    keycap,
    aligned,
    linuxPlaceholder,
    "replay",
    "linux",
  )).toBe(false);
  expect(semanticColumnsMatch(
    ascii,
    aligned,
    linuxPlaceholder,
    "tmux",
    "linux",
  )).toBe(false);
});

test("paginated semantic field lookup matches values across split cards", () => {
  const tag = SEMANTIC_TABLE_ROWS.find((row) => row.type === "Tag")!;
  const lines = [
    "│Type: Previous",
    "│Symbol: WRONG",
    "│Description: RGI tag flag",
    "│Type: Tag",
    `│Symbol: ${TAG_FLAG_SYMBOL}`,
    "│wrapped detail one",
    "│wrapped detail two",
    "│wrapped detail three",
    "│Description: Previous row",
  ];
  expect(findPaginatedSemanticFieldLines(lines, tag, "tmux")).toEqual({
    symbolLine: `│Symbol: ${TAG_FLAG_SYMBOL}`,
    descriptionLine: "│Description: RGI tag flag",
  });
});

async function waitForChangedPane(
  session: TmuxSession,
  previous: string,
  timeout = 1_000,
): Promise<string | null> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const pane = await session.capturePane();
    if (pane !== previous) return pane;
    await Bun.sleep(25);
  }
  return null;
}

async function collectFullTranscriptPages(
  session: TmuxSession,
  maxPages = 16,
): Promise<string> {
  const first = await session.capturePane();
  const pages = [first];
  let previous = first;
  for (let index = 1; index < maxPages; index += 1) {
    await session.sendHexBytes(["1b", "5b", "35", "7e"]);
    const pane = await waitForChangedPane(session, previous);
    if (pane === null) break;
    pages.push(pane);
    previous = pane;
  }
  return pages.join("\n");
}

function expectRenderedMarkdown(
  scrollback: string,
  observation: SemanticObservation,
): void {
  expect(scrollback).toContain("Resume Markdown Probe");
  expect(scrollback).toContain("RESUME_MARKDOWN_TOP_MARKER");
  expect(scrollback).toContain("✓ RESUME_MARKDOWN_TASK_MARKER");
  expect(scrollback).toContain("REPRO_TABLE_01");
  expect(scrollback).toContain("REPRO_TABLE_08");
  expect(scrollback).toContain("REPRO_TABLE_14");
  expect(scrollback).toContain("┌");
  expect(scrollback).toContain("const CODE_LINE_01 = 1;");
  expect(scrollback).toContain("const CODE_FINAL_MARKER = 18;");
  expect(scrollback).not.toContain("## Resume Markdown Probe");
  expect(scrollback).not.toContain("- [x] RESUME_MARKDOWN_TASK_MARKER");
  expect(scrollback).not.toContain("| Row | Value |");
  expect(scrollback).not.toContain("| --- | --- |");
  expect(scrollback).not.toContain("```zig");
  expect(scrollback).not.toContain("18;❯");
  expectSemanticTableRows(scrollback, observation);
}

function expectInferredTypeScriptCodeBlock(scrollback: string): void {
  expect(scrollback).toContain("┌ ts");
  expect(scrollback).toContain("inferredHook = await");
  expect(scrollback).toContain("{ cleanup: true } as");
  expect(scrollback).toContain("pSignal);");
}

function expectInferredTypeScriptColors(scrollback: string): void {
  expect(scrollback).toContain("\x1b[38;5;252mconst\x1b[39m");
  expect(scrollback).toContain("\x1b[38;5;252mawait\x1b[39m");
}

function expectExpandedCodeProfiles(scrollback: string): void {
  expect(scrollback).toContain("┌ json");
  expect(scrollback).toContain('"json_ready"');
  expect(scrollback).toContain("┌ python");
  expect(scrollback).toContain("def render_ready");
}

function expectExpandedCodeColors(scrollback: string): void {
  expect(scrollback).toContain("\x1b[38;5;252mdef\x1b[39m");
  expect(scrollback).toContain("\x1b[38;5;250m\"json_ready\"\x1b[39m");
}

function expectNoRawToolReplay(scrollback: string): void {
  expect(scrollback).not.toContain("Previous tool execution");
  expect(scrollback).not.toContain("[system] Previous tool execution");
}

function normalizeVolatileStatusRows(grid: string[]): string[] {
  return grid.map((line) =>
    /^• Thinking(?: \(\d+s\))?$/.test(line) ||
      /^• Streaming \([^)]*\)$/.test(line) ||
      isVolatileTokenStatusRow(line)
      ? "<status>"
      : line
  );
}

test("volatile status rows normalize before stable-grid comparison", () => {
  expect(normalizeVolatileStatusRows(["• Streaming (↑6 ↓5)"])).toEqual(["<status>"]);
  expect(normalizeVolatileStatusRows(["  (↑6 ↓5)"])).toEqual(["<status>"]);
  expect(normalizeVolatileStatusRows(["  0s (↑6 ↓5)"])).toEqual(["<status>"]);
});

test.skipIf(!tmuxAvailable())(
  "session resume command group opens last and explicit session ids",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-session-resume-command-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const seedStderrPath = join(root, "seed-stderr.log");
    const exactStderrPath = join(root, "exact-stderr.log");
    const lastStderrPath = join(root, "last-stderr.log");
    const title = "Save the grouped session resume fixture.";
    const marker = "GROUPED_SESSION_RESUME_FIXTURE";
    mkdirSync(home);
    mkdirSync(workspace);
    writeFileSync(seedStderrPath, "");
    writeFileSync(exactStderrPath, "");
    writeFileSync(lastStderrPath, "");

    const seedGateway = startFakeGateway([fakeGatewayFinalText(marker)]);
    const resumeGateway = startFakeGateway([]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, seedGateway),
        stderrPath: seedStderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText(title);
      await active.waitForText(marker, TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
      await active.kill();
      active = null;

      const sessionId = sessionIdFromHome(home);
      const cases = [
        {
          command: `${FX_BIN} session resume --id ${sessionId}`,
          stderrPath: exactStderrPath,
        },
        {
          command: `${FX_BIN} session resume last`,
          stderrPath: lastStderrPath,
        },
      ];
      for (const resumeCase of cases) {
        active = await TmuxSession.create({
          cmd: resumeCase.command,
          cwd: realpathSync(workspace),
          env: gatewayEnv(home, resumeGateway),
          stderrPath: resumeCase.stderrPath,
          width: 100,
          height: 30,
        });
        const resumed = await waitForScrollbackMarkers(
          active,
          [`● Session resumed: ${title}`, marker],
          TIMEOUT,
        );
        expect(resumed).toContain(marker);
        expect(active.isPaneAlive()).toBe(true);
        expect(readFileSync(resumeCase.stderrPath, "utf8")).toBe("");
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        await active.kill();
        active = null;
      }

      expect(seedGateway.requests).toHaveLength(1);
      expect(resumeGateway.requests).toHaveLength(0);
      expect(readFileSync(seedStderrPath, "utf8")).toBe("");
    } finally {
      if (active) await active.kill();
      seedGateway.stop();
      resumeGateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

function expectAltExitToPreserveNormalViewport(tapePath: string): void {
  const tape = readFileSync(tapePath);
  const leaveAlternate = Buffer.from("\x1b[?1049l");
  const leaveOffset = tape.lastIndexOf(leaveAlternate);
  expect(leaveOffset).toBeGreaterThanOrEqual(0);

  const bytesAfterExit = tape.subarray(leaveOffset + leaveAlternate.length);
  const synchronizedEnd = Buffer.from("\x1b[?2026l");
  const firstFrameEnd = bytesAfterExit.indexOf(synchronizedEnd);
  const firstNormalFrame = firstFrameEnd >= 0
    ? bytesAfterExit.subarray(0, firstFrameEnd + synchronizedEnd.length)
    : bytesAfterExit;
  expect(firstNormalFrame.includes(Buffer.from("\x1b[1;1H\x1b[2K"))).toBe(false);
}

test.skipIf(!tmuxAvailable())(
  "approved-shell command output normalizes controls in compact, Ctrl-O, and resume views",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-command-output-terminal-safety-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const resumedStderrPath = join(root, "resumed-stderr.log");
    const tracePath = join(root, "trace.log");
    const tapePath = join(root, "command-output-terminal-safety.fxtape");
    const scriptPath = join(workspace, "command-output-controls.sh");
    const ansiMarker = "ANSI_RED_TOKEN";
    const crMarker = "CR_DONE";
    const splitMarker = "éSPLIT_UTF8_DONE";
    const trailingMarker = "BOUNDARY_TRAILING";
    const literalClose = "LITERAL_CLOSE_</stdout>";
    const doneMarker = "CONTROL_OUTPUT_DONE";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");
    writeFileSync(resumedStderrPath, "");
    writeFileSync(
      scriptPath,
      `#!/bin/sh
printf '\\033[31m${ansiMarker}\\033[0m\\n'
printf 'CR_STAGE_01\\r${crMarker}\\n'
printf 'TAB\\tSTOP\\n'
printf 'NUL:\\000:END\\n'
printf 'INVALID:\\377:END\\n'
printf '  BOUNDARY_LEADING  \\n'
printf '\\n'
printf '${literalClose}\\n'
awk 'BEGIN { for (i = 0; i < 4095; i++) printf "x" }'
printf '\\303'
sleep 0.2
printf '\\251SPLIT_UTF8_DONE\\n'
printf '${trailingMarker}   '
`,
    );
    chmodSync(scriptPath, 0o755);

    const gateway = startFakeGateway([
      fakeGatewayToolCall("terminal-safety-command", "terminal", {
        action: "exec",
        command: "./command-output-controls.sh",
      }),
      fakeGatewayFinalText(doneMarker),
    ]);
    let active: TmuxSession | null = null;
    let resumedGateway: ReturnType<typeof startFakeGateway> | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,core,tool,render,transcript,command_output,session",
        },
        stderrPath,
        width: 72,
        height: 24,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared command.");
      const compact = await waitForScrollback(active, doneMarker);
      expect(compact).toContain(`│ ${ansiMarker}`);
      expect(compact).toContain(`│ ${crMarker}`);
      expect(compact).toContain("│ TAB");
      expect(compact).toContain("STOP");
      expect(compact).toContain("│ NUL:\\x00:END");
      expect(compact).toContain("│ INVALID:\\xff:END");
      expect(compact).not.toContain("CR_STAGE_01");
      expect(compact).not.toContain("\\x0d");
      expect(compact).not.toContain("\\x1b[31m");
      expect(compact).not.toContain("BOUNDARY_LEADING");
      expect(compact).not.toContain(splitMarker);
      expect(compact).not.toContain(trailingMarker);
      expect(compact).toContain("│ … 5 lines more (ctrl o to view)");
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
      expect(readFileSync(tracePath, "utf8")).toContain("route=approved_shell");

      await active.waitForPane(
        (pane) => pane.includes(doneMarker) && !pane.includes("Streaming ("),
        TIMEOUT,
      );
      const compactGrid = await active.capturePaneGrid();
      await active.resizeWindow(48, 24);
      const narrow = await active.waitForText("│ … 5 lines more (ctrl o to view)", TIMEOUT);
      expect(narrow).toContain(`│ ${ansiMarker}`);
      expect(narrow).not.toContain(trailingMarker);
      await active.resizeWindow(72, 24);
      await active.waitForText(doneMarker, TIMEOUT);
      expect(normalizeVolatileStatusRows(
        await active.waitForStableGrid(compactGrid, normalizeVolatileStatusRows, TIMEOUT),
      )).toEqual(
        normalizeVolatileStatusRows(compactGrid),
      );

      const tape = readFileSync(tapePath);
      expect(tape.includes(Buffer.from(`│ ${ansiMarker}`))).toBe(true);
      expect(tape.includes(Buffer.from(`\x1b[31m${ansiMarker}`))).toBe(false);
      expect(tape.includes(Buffer.from(`NUL:\x00:END`))).toBe(false);
      expect(tape.includes(Buffer.from([0x49, 0x4e, 0x56, 0x41, 0x4c, 0x49, 0x44, 0x3a, 0xff])))
        .toBe(false);

      await active.sendKeys("C-o");
      await active.waitForText("┃ Review · ←/→ switch · ctrl o close", TIMEOUT);
      expect(await active.capturePane()).not.toContain(trailingMarker);
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendHexBytes(
        Array.from({ length: 80 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText(trailingMarker, TIMEOUT);
      const fullTail = await active.capturePane();
      expect(fullTail).toContain(splitMarker);
      expect(fullTail).toContain(trailingMarker);
      expect(fullTail).not.toContain("lines more (ctrl o");
      await active.sendHexBytes(
        Array.from({ length: 80 }, () => ["1b", "5b", "35", "7e"]).flat(),
      );
      await active.waitForText(ansiMarker, TIMEOUT);
      const fullHead = await active.capturePane();
      expect(fullHead).toContain(ansiMarker);
      expect(fullHead).toContain(crMarker);
      expect(fullHead).toContain("NUL:\\x00:END");
      expect(fullHead).toContain("INVALID:\\xff:END");
      expect(fullHead).not.toContain("CR_STAGE_01");
      expect(fullHead).not.toContain("\\x1b[31m");
      await active.sendHexBytes(["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"]);
      const boundaryViewport = await active.waitForPane(
        (pane) => pane !== fullHead && pane.includes("BOUNDARY_LEADING"),
        TIMEOUT,
      );
      expect(boundaryViewport).toContain("BOUNDARY_LEADING");
      await active.sendHexBytes(["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"]);
      const literalViewport = await active.waitForPane(
        (pane) => pane !== boundaryViewport && pane.includes(literalClose),
        TIMEOUT,
      );
      expect(literalViewport.match(/<\/stdout>/g)).toHaveLength(1);
      expect(literalViewport).not.toContain("<stdout>");
      await active.sendKeys("C-o");
      await active.waitForText(doneMarker, TIMEOUT);
      expect(normalizeVolatileStatusRows(
        await active.waitForStableGrid(compactGrid, normalizeVolatileStatusRows, TIMEOUT),
      )).toEqual(
        normalizeVolatileStatusRows(compactGrid),
      );

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
      await active.kill();
      active = null;

      resumedGateway = startFakeGateway([]);
      active = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, resumedGateway),
        stderrPath: resumedStderrPath,
        width: 72,
        height: 24,
      });
      await active.waitForText("│ … 5 lines more (ctrl o to view)", TIMEOUT);
      await active.sendKeys("C-o");
      await active.waitForText("┃ Review · ←/→ switch · ctrl o close", TIMEOUT);
      expect(await active.capturePane()).not.toContain(trailingMarker);
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendHexBytes(
        Array.from({ length: 80 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText(trailingMarker, TIMEOUT);
      const resumedTail = await active.capturePane();
      expect(resumedTail).toContain(splitMarker);
      expect(resumedTail).toContain(trailingMarker);
      expect(resumedGateway.requests).toHaveLength(0);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");

      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain(ansiMarker);
      expect(replay.stdout).toContain("NUL:\\x00:END");
      expect(replay.stdout).toContain("INVALID:\\xff:END");
      expect(replay.stdout).toContain(splitMarker);
      expect(replay.stdout).toContain(trailingMarker);
      expect(replay.stdout).toContain(doneMarker);
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      resumedGateway?.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O opens retained command output in the alternate buffer and restores compact inline output",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o.fxtape");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const tailMarker = "FULL_CTRL_O_LINE_3000";
    const commandArgumentTail = "FULL_CTRL_O_COMMAND_ARGUMENT_TAIL";
    const command =
      "awk 'BEGIN { for (i = 1; i <= 3000; i++) printf \"FULL_CTRL_O_LINE_%04d\\n\", i }'" +
      ` # ${"argument-padding-".repeat(8)}${commandArgumentTail}`;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-command", "terminal", { action: "exec", command }),
      fakeGatewayFinalText("FULL_CTRL_O_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, gateway), FX_RECORD: tapePath },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared command.");
      await waitForScrollback(
        active,
        "│ … 2995 lines more (ctrl o to view)",
      );
      const compact = await waitForScrollback(active, "FULL_CTRL_O_DONE");
      expect(compact).not.toContain(tailMarker);
      await active.waitForPane(
        (pane) => pane.includes("FULL_CTRL_O_DONE") && !pane.includes("Streaming ("),
        TIMEOUT,
      );
      const compactGrid = await active.capturePaneGrid();

      await active.sendKeys("C-o");
      await active.waitForText("Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close", TIMEOUT);
      const review = await active.capturePane();
      expect(review).toContain("FULL_CTRL_O_LINE_0001");
      expect(review).toContain("FULL_CTRL_O_LINE_0003");
      expect(review).not.toContain("FULL_CTRL_O_LINE_0004");
      expect(review).not.toContain(tailMarker);
      expect(review).not.toContain(commandArgumentTail);
      expect(review).toContain("2997 more lines · → to expand");
      expect(review).not.toMatch(/^\s*input\s*$/m);

      await active.sendKeys("Right");
      await active.waitForText("Full detail · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close", TIMEOUT);
      const expandedAtTail = await active.capturePane();
      expect(expandedAtTail).toContain(tailMarker);
      expect(expandedAtTail).not.toContain("FULL_CTRL_O_LINE_0001");

      await active.sendKeys(Array.from({ length: 140 }, () => "PPage").join(" "));
      const expandedAtHead = await active.waitForText("command: awk", TIMEOUT);
      expect(expandedAtHead).toContain(commandArgumentTail);
      expect(expandedAtHead).toContain("FULL_CTRL_O_LINE_0001");
      expect(expandedAtHead).not.toContain(tailMarker);

      await active.sendKeys(Array.from({ length: 140 }, () => "NPage").join(" "));
      await active.waitForText(tailMarker, TIMEOUT);
      const full = await active.capturePane();
      expect(full).toContain(tailMarker);
      expect(full).not.toContain("lines more (ctrl o");
      expect(full).toContain("Full detail · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close");

      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      const afterPageUp = await active.waitForPane(
        (pane) =>
          pane !== full &&
          !pane.includes(tailMarker) &&
          /FULL_CTRL_O_LINE_\d{4}/.test(pane),
        TIMEOUT,
      );
      await active.sendHexBytes(["1b", "5b", "36", "7e"]);
      const tailAfterPageDown = await active.waitForText(tailMarker, TIMEOUT);

      for (let i = 0; i < 12; i += 1) {
        await active.sendHexBytes(["1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d"]);
      }
      await active.waitForPane(
        (pane) =>
          pane !== tailAfterPageDown &&
          !pane.includes(tailMarker) &&
          /FULL_CTRL_O_LINE_\d{4}/.test(pane),
        TIMEOUT,
      );
      for (let i = 0; i < 12; i += 1) {
        await active.sendHexBytes(["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"]);
      }
      await active.waitForText(tailMarker, TIMEOUT);

      await active.sendKeys("Left");
      await active.waitForText("Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close", TIMEOUT);
      await active.sendKeys("C-o");
      await active.waitForText("│ … 2995 lines more (ctrl o to view)", TIMEOUT);
      const restored = await active.capturePane();
      const restoredScrollback = await active.captureFullScrollback();
      expect(restored).toContain("│ … 2995 lines more (ctrl o to view)");
      expect(restored).not.toContain(tailMarker);
      expect(normalizeVolatileStatusRows(await active.capturePaneGrid())).toEqual(
        normalizeVolatileStatusRows(compactGrid),
      );
      expect(countOccurrences(restoredScrollback, "FULL_CTRL_O_DONE")).toBe(1);
      expectAltExitToPreserveNormalViewport(tapePath);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "cap-crossing command output returns to input and accepts slash commands",
  async () => {
    const timeout = 120_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-command-output-cap-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tracePath = join(root, "trace.log");
    const tapePath = join(root, "command-output-cap.fxtape");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const lineCount = 12_000;
    const padding = "X".repeat(96);
    const tailIndex = String(lineCount).padStart(5, "0");
    const stdoutTail = `CAP_STDOUT_${tailIndex}_${padding}`;
    const stderrTail = `CAP_STDERR_${tailIndex}_${padding}`;
    const command =
      `awk 'BEGIN { pad="${padding}"; for (i = 1; i < ${lineCount}; i++) { ` +
      `printf "CAP_STDOUT_%05d_%s\\n", i, pad; ` +
      `printf "CAP_STDERR_%05d_%s\\n", i, pad > "/dev/stderr" } }'; ` +
      `printf '${stdoutTail}\\n'; sleep 0.05; printf '${stderrTail}\\n' >&2`;
    const finalMarker = "CAP_CROSSING_DONE";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("cap-crossing-command", "terminal", { action: "exec", command }),
      fakeGatewayFinalText(finalMarker),
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,tool,worker,render,transcript,command_output",
        },
        stderrPath,
        width: 160,
        height: 200,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared cap-crossing command.");
      await waitForScrollback(
        active,
        `│ … ${lineCount * 2 - 5} lines more (ctrl o to view)`,
        timeout,
      );
      const compact = await waitForScrollback(active, finalMarker, timeout);
      expect(compact).not.toContain(stdoutTail);
      expect(compact).not.toContain(stderrTail);

      await active.sendText("/status");
      const status = await active.waitForText(/model|permission_mode/i, TIMEOUT);
      expect(status.toLowerCase()).toMatch(/model|permission_mode/);
      expect(active.paneStatus()).toEqual({ dead: false, status: null });
      const sessionId = sessionIdFromHome(home);

      const commandDir = join(home, ".fx", "sessions", sessionId, "logs", "commands");
      const artifactFiles = readdirSync(commandDir);
      const stdoutName = artifactFiles.find((name) => name.endsWith(".stdout.log"));
      const stderrName = artifactFiles.find((name) => name.endsWith(".stderr.log"));
      expect(stdoutName).toBeDefined();
      expect(stderrName).toBeDefined();
      const stdoutArtifact = readFileSync(join(commandDir, stdoutName!), "utf8");
      const stderrArtifact = readFileSync(join(commandDir, stderrName!), "utf8");
      expect(stdoutArtifact.trimEnd().split("\n")).toHaveLength(lineCount);
      expect(stderrArtifact.trimEnd().split("\n")).toHaveLength(lineCount);
      expect(stdoutArtifact).toContain(stdoutTail);
      expect(stderrArtifact).toContain(stderrTail);

      const replay = await runFx(["replay", tapePath, "--json"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      const replayJson = JSON.parse(replay.stdout);
      expect(replayJson.frame_count).toBeGreaterThan(0);
      expect(replayJson.stdout_bytes).toBeGreaterThan(0);
      expect(readFileSync(tracePath, "utf8")).toContain(
        "command output retention cap reached",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(2);
      passed = true;
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained cap-crossing artifacts at ${root}`);
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "active command overflow marks Ctrl-O incomplete until terminal replay attaches",
  async () => {
    const timeout = 120_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-command-output-active-overflow-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tracePath = join(root, "trace.log");
    const scriptPath = join(workspace, "active-overflow.sh");
    const readyPath = join(workspace, ".active-overflow-ready");
    const continuePath = join(workspace, ".active-overflow-continue");
    const continuedReadyPath = join(workspace, ".active-overflow-continued-ready");
    const releasePath = join(workspace, ".active-overflow-release");
    const historicalSentinel = "ACTIVE_OVERFLOW_HISTORICAL_SENTINEL";
    const historyTailMarker = "ACTIVE_OVERFLOW_HISTORY_080";
    const stableMarker = "ACTIVE_OVERFLOW_STABLE_HEAD";
    const unstableMarker = "ACTIVE_OPEN_000000";
    const continuedMarker = "ACTIVE_OVERFLOW_LIVE_CONTINUATION";
    const tailMarker = "ACTIVE_OVERFLOW_TAIL";
    const doneMarker = "ACTIVE_OVERFLOW_DONE";
    const futureMarker = "│ … full output available when command finishes";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");
    writeFileSync(
      scriptPath,
      `#!/bin/sh
printf '${stableMarker}\\n'
awk 'BEGIN { for (i = 0; i < 60000; i++) printf "ACTIVE_OPEN_%06d ", i }'
: > .active-overflow-ready
while [ ! -f .active-overflow-continue ]; do sleep 0.02; done
printf '\\n${continuedMarker}\\n'
sleep 0.2
: > .active-overflow-continued-ready
while [ ! -f .active-overflow-release ]; do sleep 0.02; done
printf '${tailMarker}\\n'
`,
    );
    chmodSync(scriptPath, 0o755);

    const historicalRows = Array.from({ length: 80 }, (_, index) =>
      index === 4
        ? historicalSentinel
        : `ACTIVE_OVERFLOW_HISTORY_${String(index + 1).padStart(3, "0")}`
    );
    const gateway = startFakeGateway([
      fakeGatewayFinalText(historicalRows.join("\n")),
      fakeGatewayToolCall("active-overflow-command", "terminal", {
        action: "exec",
        command: "./active-overflow.sh",
      }),
      fakeGatewayFinalText(doneMarker),
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "agent,core,tool,worker,render,transcript,command_output,transcript_retention,session",
        },
        stderrPath,
        width: 80,
        height: 28,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Seed the prepared historical transcript.");
      await active.waitForText(historyTailMarker, timeout);
      await active.sendText("Run the prepared active overflow command.");
      await waitForCondition(
        () => existsSync(readyPath),
        "the active overflow command readiness file",
        timeout,
      );
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("command output retention cap reached"),
        "the active command structured-retention overflow",
        timeout,
      );
      const activeCompact = await active.waitForPane(
        (pane) =>
          pane.includes(stableMarker) &&
          /│ … \d+ (?:line|lines) more \(ctrl o to view\)/.test(pane),
        timeout,
      );
      const compactOutputRows = activeCompact.split("\n").filter((line) =>
        line.trimStart().startsWith("│ ") && !line.includes("ctrl o to view")
      );
      expect(compactOutputRows).toHaveLength(5);
      expect(activeCompact).not.toContain(tailMarker);
      expect(activeCompact.match(/● Running/g)).toHaveLength(1);

      await active.sendKeys("C-o");
      await active.waitForText(futureMarker, timeout);
      const partialFull = await active.capturePane();
      expect(partialFull).toContain(stableMarker);
      expect(partialFull).toContain(futureMarker);
      expect(partialFull).not.toContain(unstableMarker);
      expect(partialFull).not.toContain(tailMarker);

      await active.sendHexBytes(
        Array.from({ length: 8 }, () => ["1b", "5b", "35", "7e"]).flat(),
      );
      await active.waitForText(historicalSentinel, timeout);
      const scrolledHistory = (await active.capturePaneGrid()).filter((row) =>
        row.includes("ACTIVE_OVERFLOW_HISTORY_") || row.includes(historicalSentinel)
      );
      expect(scrolledHistory.length).toBeGreaterThan(5);

      writeFileSync(continuePath, "continue\n");
      await waitForCondition(
        () => existsSync(continuedReadyPath),
        "more active output while Ctrl-O is scrolled",
        timeout,
      );
      await active.waitForText(historicalSentinel, timeout);
      const historyAfterMoreOutput = (await active.capturePaneGrid()).filter((row) =>
        row.includes("ACTIVE_OVERFLOW_HISTORY_") || row.includes(historicalSentinel)
      );
      expect(historyAfterMoreOutput).toEqual(scrolledHistory);

      await active.sendHexBytes(
        Array.from({ length: 8 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText(futureMarker, timeout);
      await active.sendKeys("Escape");
      await active.waitForPane(
        (pane) =>
          pane.includes(stableMarker) &&
          pane.includes("lines more (ctrl o") &&
          !pane.includes(futureMarker),
        timeout,
      );
      writeFileSync(releasePath, "release\n");
      await active.waitForText(doneMarker, timeout);
      await waitForCondition(
        () => gateway.requests.length === 3,
        "the post-command Gateway continuation",
        timeout,
      );

      const terminalCompact = await active.capturePane();
      expect(terminalCompact).toContain(stableMarker);
      expect(terminalCompact).toContain("lines more (ctrl o");
      expect(terminalCompact).not.toContain(tailMarker);
      expect(terminalCompact).not.toContain(futureMarker);
      const sessionId = sessionIdFromHome(home);
      const commandDir = join(home, ".fx", "sessions", sessionId, "logs", "commands");
      const combinedName = readdirSync(commandDir).find((name) =>
        name.endsWith(".log") &&
        !name.endsWith(".stdout.log") &&
        !name.endsWith(".stderr.log")
      );
      expect(combinedName).toBeDefined();
      const artifact = readFileSync(join(commandDir, combinedName!), "utf8");
      expect(Buffer.byteLength(artifact)).toBeGreaterThan(1024 * 1024);
      expect(artifact).toContain(stableMarker);
      expect(artifact).toContain("ACTIVE_OPEN_059999");
      expect(artifact).toContain(continuedMarker);
      expect(artifact).toContain(tailMarker);

      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (active) {
        if (passed) {
          try {
            await active.sendText("/quit");
          } catch {}
        }
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained active-overflow artifacts at ${root}`);
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "cancelled cap-crossing command keeps inline rows stable and Ctrl-O opens its complete artifact",
  async () => {
    const timeout = 60_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cancelled-command-cap-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tracePath = join(root, "trace.log");
    const tapePath = join(root, "cancelled-command-cap.fxtape");
    const beforePath = join(root, "scrollback-before.txt");
    const beforeAnsiPath = join(root, "scrollback-before.ansi.txt");
    const afterPath = join(root, "scrollback-after.txt");
    const afterAnsiPath = join(root, "scrollback-after.ansi.txt");
    const ctrlOPath = join(root, "ctrl-o.txt");
    const rowPrefix = "CANCEL_CAP_ROW_";
    const tailMarker = "CANCEL_CAP_TERM_TAIL_ONLY";
    const nextMarker = "CANCEL_CAP_UNRELATED_TURN_DONE";
    const callId = "cancelled-cap-command";
    const readyPath = join(workspace, ".cancel-cap-ready");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");
    writeFileSync(join(workspace, ".cancel-cap-row-prefix"), rowPrefix);
    writeFileSync(join(workspace, ".cancel-cap-tail-marker"), tailMarker);
    const scriptPath = join(workspace, "cancel-cap.sh");
    writeFileSync(
      scriptPath,
      `#!/bin/sh
row_prefix=$(cat .cancel-cap-row-prefix)
tail_marker=$(cat .cancel-cap-tail-marker)
trap 'printf "%s\\n" "$tail_marker"; exit 0' TERM
i=1
while [ "$i" -le 24 ]; do
  printf "%s%02d\\n" "$row_prefix" "$i"
  i=$((i + 1))
done
awk 'BEGIN { for (i = 1; i <= 600; i++) printf "CAP_FILL_%04d_%02000d\\n", i, 0 }'
: > .cancel-cap-ready
while :; do :; done
`,
    );
    chmodSync(scriptPath, 0o755);

    const expectedRows = Array.from(
      { length: 24 },
      (_, index) => `${rowPrefix}${String(index + 1).padStart(2, "0")}`,
    );
    const historicalLines = (text: string): string[] =>
      text.split("\n").filter((line) => line.includes(rowPrefix));
    let releaseNextResponse: (() => void) | null = null;
    const nextResponse = new Promise<Response>((resolve) => {
      releaseNextResponse = () => resolve(
        fakeGatewayFinalText(`${nextMarker}\n${"N".repeat(8 * 1024)}`),
      );
    });
    const gateway = startFakeGateway([
      fakeGatewayToolCall(callId, "terminal", { action: "exec", command: "./cancel-cap.sh" }),
      () => nextResponse,
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "core,agent,tool,worker,interrupt,command_output,transcript,transcript_retention,render",
        },
        stderrPath,
        width: 120,
        height: 36,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared cancellable cap-crossing command.");
      await waitForScrollback(active, expectedRows[4]!, timeout);
      await waitForCondition(
        () => existsSync(readyPath),
        "the cap-crossing command readiness file",
        timeout,
      );
      await waitForCondition(
        () => existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("command output retention cap reached"),
        "the structured command-output retention cap",
        timeout,
      );

      await active.sendKeys("Escape");
      await waitForScrollback(active, "Cancelled", timeout);
      await waitForScrollback(active, "│ … 619 lines more (ctrl o to view)", timeout);
      await waitForCondition(
        () => readFileSync(tracePath, "utf8").includes("event=interrupt_persisted"),
        "interrupted command finalization",
        timeout,
      );
      expect(gateway.requests).toHaveLength(1);

      const before = await active.captureFullScrollback();
      const beforeAnsi = await active.captureFullScrollbackEscapes();
      writeFileSync(beforePath, before);
      writeFileSync(beforeAnsiPath, beforeAnsi);
      const beforePlain = stripAnsi(before);
      for (const row of expectedRows.slice(0, 5)) {
        expect(countOccurrences(beforePlain, row)).toBe(1);
      }
      for (const row of expectedRows.slice(5)) {
        expect(countOccurrences(beforePlain, row)).toBe(0);
      }
      expect(historicalLines(before).map(stripAnsi)).toEqual(
        expectedRows.slice(0, 5).map((row) => expect.stringContaining(row)),
      );
      expect(beforePlain).not.toContain(tailMarker);

      const sessionId = sessionIdFromHome(home);
      const commandDir = join(home, ".fx", "sessions", sessionId, "logs", "commands");
      const combinedName = readdirSync(commandDir).find((name) =>
        name.endsWith(".log") &&
        !name.endsWith(".stdout.log") &&
        !name.endsWith(".stderr.log")
      );
      expect(combinedName).toBeDefined();
      const combinedPath = join(commandDir, combinedName!);
      const artifact = readFileSync(combinedPath, "utf8");
      expect(Buffer.byteLength(artifact)).toBeGreaterThan(1024 * 1024);
      expect(artifact).toContain(expectedRows[0]!);
      expect(artifact).toContain(expectedRows.at(-1)!);
      expect(artifact).toContain("CAP_FILL_0600_");
      expect(artifact).toContain(tailMarker);

      await active.sendKeys("C-o");
      await active.waitForText("┃ Review · ←/→ switch · ctrl o close", timeout);
      expect(await active.capturePane()).not.toContain(tailMarker);
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", timeout);
      await active.sendHexBytes(
        Array.from({ length: 500 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText(tailMarker, timeout);
      writeFileSync(ctrlOPath, await active.capturePane());
      await active.sendKeys("C-o");
      await active.waitForPane(
        (pane) =>
          pane.includes("│ … 619 lines more (ctrl o to view)") &&
          !pane.includes(tailMarker),
        timeout,
      );
      expect(historicalLines(await active.captureFullScrollback()).map(stripAnsi)).toEqual(
        historicalLines(before).map(stripAnsi),
      );

      await active.sendText("Reply with the unrelated turn marker.");
      await waitForCondition(
        () => gateway.requests.length === 2,
        "the unrelated follow-up request",
        timeout,
      );
      const retentionMarker = "[transcript_retention] pruned command output line";
      const retentionBeforeAssistant = countOccurrences(
        readFileSync(tracePath, "utf8"),
        retentionMarker,
      );
      releaseNextResponse();
      releaseNextResponse = null;
      await waitForScrollback(active, nextMarker, timeout);
      expect(gateway.requests).toHaveLength(2);
      const after = await active.captureFullScrollback();
      const afterAnsi = await active.captureFullScrollbackEscapes();
      writeFileSync(afterPath, after);
      writeFileSync(afterAnsiPath, afterAnsi);
      expect(historicalLines(after)).toEqual(historicalLines(before));
      expect(historicalLines(afterAnsi)).toEqual(historicalLines(beforeAnsi));
      await waitForCondition(
        () => countOccurrences(readFileSync(tracePath, "utf8"), retentionMarker) >
          retentionBeforeAssistant,
        "the recorded assistant-stream retention pass",
        timeout,
      );

      const followRequest = JSON.parse(gateway.requests[1]!.body) as {
        prompt: Array<{ role: string; content: unknown }>;
      };
      const parts = followRequest.prompt.flatMap((message) =>
        Array.isArray(message.content) ? message.content : []
      ) as Array<Record<string, unknown>>;
      const calls = parts.filter((part) =>
        part.type === "tool-call" &&
        part.toolCallId === callId &&
        part.toolName === "terminal"
      );
      const results = parts.filter((part) =>
        part.type === "tool-result" &&
        part.toolCallId === callId &&
        part.toolName === "terminal"
      );
      expect(calls).toHaveLength(1);
      expect(results).toHaveLength(1);
      expect(JSON.stringify(results[0])).toContain("aborted by user");
      expect(gateway.requests[1]!.body).toContain("<turn_aborted>");
      expect(gateway.requests[1]!.body).not.toContain(rowPrefix);
      expect(gateway.requests[1]!.body).not.toContain("CAP_FILL_0600_");
      expect(gateway.requests[1]!.body).not.toContain(tailMarker);
      expect(gateway.requests[1]!.body).not.toContain(combinedName!);
      expect(gateway.requests[1]!.body).not.toContain(combinedPath);
      expect(readFileSync(combinedPath, "utf8")).toBe(artifact);
      expect(active.isPaneAlive()).toBe(true);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const replayFrames = await runFx(["replay", tapePath, "--frames"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
        timeoutMs: timeout,
      });
      expect(replayFrames.code).toBe(0);
      expect(replayFrames.stderr).toBe("");
      expect(replayFrames.stdout).toContain(expectedRows[0]!);
      expect(replayFrames.stdout).toContain(tailMarker);
      expect(replayFrames.stdout).toContain(nextMarker);
      const replayJson = await runFx(["replay", tapePath, "--json"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
        timeoutMs: timeout,
      });
      expect(replayJson.code).toBe(0);
      expect(replayJson.stderr).toBe("");
      expect(JSON.parse(replayJson.stdout).frame_count).toBeGreaterThan(0);

      const trace = readFileSync(tracePath, "utf8");
      const artifactIndex = trace.indexOf("command output artifact created");
      const interruptIndex = trace.indexOf("event=interrupt_persisted");
      expect(trace).toContain("route=approved_shell");
      expect(artifactIndex).toBeGreaterThanOrEqual(0);
      expect(interruptIndex).toBeGreaterThan(artifactIndex);
      expect(trace).not.toContain("dropping buffered command output");
      expect(trace).not.toContain(
        "cancelled worker event dropped kind=command_output_complete",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      releaseNextResponse?.();
      if (active) {
        if (!passed) {
          try {
            writeFileSync(join(root, "failure-scrollback.txt"), await active.captureFullScrollback());
            writeFileSync(
              join(root, "failure-scrollback.ansi.txt"),
              await active.captureFullScrollbackEscapes(),
            );
          } catch {}
        } else {
          try {
            await active.sendText("/quit");
          } catch {}
        }
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained cancelled cap-crossing artifacts at ${root}`);
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "cancelled below-cap command exposes its TERM tail only through Ctrl-O",
  async () => {
    const timeout = 60_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cancelled-command-below-cap-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tracePath = join(root, "trace.log");
    const tapePath = join(root, "cancelled-command-below-cap.fxtape");
    const headMarker = "CANCEL_BELOW_CAP_HEAD";
    const tailMarker = "CANCEL_BELOW_CAP_TERM_TAIL_ONLY";
    const readyPath = join(workspace, ".cancel-below-ready");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");
    writeFileSync(join(workspace, ".cancel-below-head"), headMarker);
    writeFileSync(join(workspace, ".cancel-below-tail"), tailMarker);
    const scriptPath = join(workspace, "cancel-below.sh");
    writeFileSync(
      scriptPath,
      `#!/bin/sh
head_marker=$(cat .cancel-below-head)
tail_marker=$(cat .cancel-below-tail)
trap 'printf "%s\\n" "$tail_marker"; exit 0' TERM
printf "%s\\n" "$head_marker"
: > .cancel-below-ready
while :; do :; done
`,
    );
    chmodSync(scriptPath, 0o755);

    const gateway = startFakeGateway([
      fakeGatewayToolCall("cancelled-below-cap-command", "terminal", {
        action: "exec",
        command: "./cancel-below.sh",
      }),
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "core,agent,tool,worker,interrupt,command_output,transcript,render",
        },
        stderrPath,
        width: 120,
        height: 36,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared cancellable below-cap command.");
      await waitForScrollback(active, headMarker, timeout);
      await waitForCondition(
        () => existsSync(readyPath),
        "the below-cap command readiness file",
        timeout,
      );
      await active.sendKeys("Escape");
      await waitForScrollback(active, "Cancelled", timeout);
      await waitForCondition(
        () => existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=interrupt_persisted"),
        "below-cap interrupted command finalization",
        timeout,
      );

      expect(gateway.requests).toHaveLength(1);
      const compact = await active.captureFullScrollback();
      expect(countOccurrences(compact, headMarker)).toBe(1);
      expect(compact).not.toContain(tailMarker);
      const sessionId = sessionIdFromHome(home);
      const commandDir = join(home, ".fx", "sessions", sessionId, "logs", "commands");
      const combinedName = readdirSync(commandDir).find((name) =>
        name.endsWith(".log") &&
        !name.endsWith(".stdout.log") &&
        !name.endsWith(".stderr.log")
      );
      expect(combinedName).toBeDefined();
      const artifact = readFileSync(join(commandDir, combinedName!), "utf8");
      expect(Buffer.byteLength(artifact)).toBeLessThan(64 * 1024);
      expect(artifact).toBe(`${headMarker}\n${tailMarker}\n`);

      await active.sendKeys("C-o");
      await active.waitForText(tailMarker, timeout);
      expect(await active.capturePane()).toContain(tailMarker);
      await active.sendKeys("Escape");
      await active.waitForPane(
        (pane) => pane.includes(headMarker) && !pane.includes(tailMarker),
        timeout,
      );
      expect(await active.captureFullScrollback()).not.toContain(tailMarker);
      expect(active.isPaneAlive()).toBe(true);

      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
        timeoutMs: timeout,
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain(headMarker);
      expect(replay.stdout).toContain(tailMarker);
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("route=approved_shell");
      expect(trace).not.toContain("command output retention cap reached");
      expect(trace).not.toContain("dropping buffered command output");
      expect(trace).not.toContain(
        "cancelled worker event dropped kind=command_output_complete",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (active) {
        if (!passed) {
          try {
            writeFileSync(join(root, "failure-scrollback.txt"), await active.captureFullScrollback());
          } catch {}
        } else {
          try {
            await active.sendText("/quit");
          } catch {}
        }
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained cancelled below-cap artifacts at ${root}`);
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "inline command output follows completed tool status and Ctrl-O keeps detail",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-command-output-status-order-")));
    const home = join(root, "home");
    const workspaceDir = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tracePath = join(root, "trace.log");
    const tapePath = join(root, "command-output-status-order.fxtape");
    const inlineScrollbackPath = join(root, "inline-scrollback.txt");
    const inlineAnsiPath = join(root, "inline-scrollback.ansi.txt");
    const ctrlOScrollbackPath = join(root, "ctrl-o-scrollback.txt");
    const ctrlOAnsiPath = join(root, "ctrl-o-scrollback.ansi.txt");
    const replayJsonPath = join(root, "replay.json");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspaceDir);
    const workspace = realpathSync(workspaceDir);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const finalMarker = "ORDER_REPRO_DONE";
    const prompt =
      "Use the shell tool to run exactly pwd and no other commands. Then reply with the completion marker.";
    const statusLine = "● Ran pwd";
    const outputLine = workspace;
    const reviewOutputPrefix = workspace.slice(0, 56);
    const visibleLinearText = (text: string): string =>
      stripAnsi(text).replaceAll("\n│ ", "").replaceAll("\n", "");
    const captureFullScrollbackArtifacts = async (
      session: TmuxSession,
      plainPath: string,
      ansiPath: string,
    ): Promise<string> => {
      const plain = await session.captureFullScrollback();
      const ansi = await session.captureFullScrollbackEscapes();
      writeFileSync(plainPath, plain);
      writeFileSync(ansiPath, ansi);
      return visibleLinearText(ansi);
    };
    const expectInlineOrder = (scrollback: string): void => {
      expect(countOccurrences(scrollback, statusLine)).toBe(1);

      const statusIndex = scrollback.indexOf(statusLine);
      const doneIndex = scrollback.lastIndexOf(finalMarker);
      expect(statusIndex).toBeGreaterThanOrEqual(0);
      expect(doneIndex).toBeGreaterThan(statusIndex);
      const transcriptRegion = scrollback.slice(statusIndex, doneIndex);
      expect(countOccurrences(transcriptRegion, outputLine)).toBe(1);
      const outputIndex = scrollback.indexOf(outputLine, statusIndex);
      expect(outputIndex).toBeGreaterThan(statusIndex);
      expect(doneIndex).toBeGreaterThan(outputIndex);
    };
    const gateway = startFakeGateway([
      fakeGatewayToolCall("order-repro-pwd", "terminal", { action: "exec", command: "pwd" }),
      fakeGatewayFinalText(finalMarker),
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,tool,render,transcript,gateway",
        },
        stderrPath,
        width: 100,
        height: 28,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText(prompt);
      await waitForScrollback(active, finalMarker);

      const inlineVisible = await captureFullScrollbackArtifacts(
        active,
        inlineScrollbackPath,
        inlineAnsiPath,
      );
      expect(gateway.requests).toHaveLength(2);
      expectInlineOrder(inlineVisible);

      await active.sendKeys("C-o");
      await active.waitForPane((pane) => {
        const visible = visibleLinearText(pane);
        return visible.includes("Ran pwd") && visible.includes(reviewOutputPrefix);
      }, TIMEOUT);
      const ctrlOVisible = await captureFullScrollbackArtifacts(
        active,
        ctrlOScrollbackPath,
        ctrlOAnsiPath,
      );
      expect(ctrlOVisible).toContain("Ran pwd");
      expect(ctrlOVisible).toContain(reviewOutputPrefix);
      expect(ctrlOVisible).not.toContain("\"command\":\"pwd\"");
      expect(ctrlOVisible).not.toContain("<stdout>");
      expect(ctrlOVisible).not.toContain("</stdout>");

      const replay = await runFx(["replay", tapePath, "--json"], {
        cwd: workspace,
        env: { HOME: home },
      });
      writeFileSync(replayJsonPath, replay.stdout);
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      const replayJson = JSON.parse(replay.stdout);
      expect(replayJson.frame_count).toBeGreaterThan(0);
      expect(replayJson.stdout_bytes).toBeGreaterThan(0);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
      passed = true;
    } finally {
      if (active) {
        if (!passed) {
          try {
            writeFileSync(join(root, "failure-inline-scrollback.txt"), await active.captureFullScrollback());
            writeFileSync(join(root, "failure-inline-scrollback.ansi.txt"), await active.captureFullScrollbackEscapes());
          } catch {}
        }
        try {
          await active.sendKeys("Escape");
        } catch {}
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained command-output status-order artifacts at ${root}`);
      }
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "streamed document append preserves native scrollback without ONLCR",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-document-append-newlines-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const markers = Array.from(
      { length: 14 },
      (_, index) => `WIRE_LINE_${String(index + 1).padStart(2, "0")}`,
    );
    const response = [
      "```ts",
      ...markers.map((marker, index) => `const ${marker} = ${index + 1};`),
      "```",
      "WIRE_APPEND_DONE",
    ].join("\r\n");
    const terminalModes = ["stty opost onlcr", "stty opost -onlcr", "stty -opost"];

    try {
      for (const stty of terminalModes) {
        writeFileSync(stderrPath, "");
        const gateway = startFakeGateway([
          () => streamedTextResponse(response),
        ]);
        const launch = `${stty}; exec ${shellQuote(FX_BIN)}`;
        let active: TmuxSession | null = null;
        try {
          active = await TmuxSession.create({
            cmd: `zsh -lc ${shellQuote(launch)}`,
            cwd: realpathSync(workspace),
            env: gatewayEnv(home, gateway),
            stderrPath,
            width: 48,
            height: 12,
          });
          await active.waitForComposer(TIMEOUT);
          await active.sendText("Return the prepared TypeScript block.");
          const scrollback = await waitForScrollback(active, "WIRE_APPEND_DONE");
          const markerRows = scrollback.split("\n").filter((line) =>
            line.includes("WIRE_LINE_")
          );

          expect(markerRows).toHaveLength(markers.length);
          for (const marker of markers) {
            expect(countOccurrences(scrollback, marker)).toBe(1);
          }
          const markerColumns = markerRows.map((line) => line.indexOf("WIRE_LINE_"));
          expect(new Set(markerColumns).size).toBe(1);
          const rows = scrollback.split("\n");
          const firstMarkerRow = rows.findIndex((line) => line.includes(markers[0]!));
          expect(markerRows).toEqual(rows.slice(firstMarkerRow, firstMarkerRow + markers.length));
          expect(scrollback.indexOf(markers.at(-1)!)).toBeLessThan(
            scrollback.indexOf("WIRE_APPEND_DONE"),
          );
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          if (active) await active.kill();
          gateway.stop();
        }
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "slow shell streaming keeps normal inline scrollback lossless",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-slow-command-output-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const marker = "SLOW_STREAM_DONE";
    const command =
      "zsh -lc 'for i in {001..080}; do print -r -- \"SLOW_STREAM $i\"; sleep 0.05; done'";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("slow-command-output", "terminal", { action: "exec", command }),
      fakeGatewayFinalText(marker),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
        },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared streaming command.");
      const scrollback = await waitForScrollback(active, marker);

      const duplicateLines: string[] = [];
      for (let i = 1; i <= 5; i += 1) {
        const line = `│ SLOW_STREAM ${String(i).padStart(3, "0")}`;
        const count = countOccurrences(scrollback, line);
        if (count !== 1) duplicateLines.push(`${line}: ${count}`);
      }
      expect(duplicateLines).toEqual([]);
      expect(scrollback).not.toContain("│ SLOW_STREAM 006");
      expect(scrollback).not.toContain("│ SLOW_STREAM 080");
      expect(scrollback).toContain("│ … 75 lines more (ctrl o to view)");
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-C closes the Ctrl-O viewer without clearing the unsent draft",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-draft-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o-draft.fxtape");
    const sentinel = "CTRL_O_DRAFT_SCROLLBACK_SENTINEL";
    const draft = "CTRL_O_UNSENT_DRAFT";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(stderrPath, "");

    const cmd = `zsh -lc 'for i in {1..14}; do printf "${sentinel}_%02d: pre-Fx shell scrollback\\n" "$i"; done; exec ${FX_BIN}'`;
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd,
        cwd: realpathSync(workspace),
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          NO_COLOR: "1",
        },
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      const before = await active.captureFullScrollback();
      for (const index of [9, 10, 11]) {
        expect(before).toContain(`${sentinel}_${index.toString().padStart(2, "0")}: pre-Fx shell scrollback`);
      }

      await active.sendLiteralText(draft);
      await active.waitForText(draft, TIMEOUT);
      await active.sendKeys("C-o");
      await Bun.sleep(150);
      const entered = readFileSync(tapePath);
      const enterAlternate = Buffer.from("\x1b[?1049h");
      const enterOffset = entered.lastIndexOf(enterAlternate);
      expect(enterOffset).toBeGreaterThanOrEqual(0);

      await active.sendKeys("C-c");
      await active.waitForText(draft, TIMEOUT);

      const restored = await active.captureFullScrollback();
      for (const index of [9, 10, 11]) {
        expect(restored).toContain(`${sentinel}_${index.toString().padStart(2, "0")}: pre-Fx shell scrollback`);
      }
      expect(restored).toContain(`┃ ${draft}`);
      expect(restored).not.toContain("press ctrl+c again to exit");

      const tape = readFileSync(tapePath);
      const leaveAlternate = Buffer.from("\x1b[?1049l");
      const leaveOffset = tape.lastIndexOf(leaveAlternate);
      expect(leaveOffset).toBeGreaterThan(enterOffset);
      expectAltExitToPreserveNormalViewport(tapePath);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Cmd+R refuses session switching over a draft and opens after explicit clear",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-session-picker-draft-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const saved = "CMD_R_SAVED_SESSION";
    const draft = "CMD_R_UNSENT_DRAFT";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(stderrPath, "");

    const gateway = startFakeGateway([fakeGatewayFinalText(saved)]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save a session before testing Cmd+R.");
      await active.waitForText(saved, TIMEOUT);
      await active.sendLiteralText(draft);
      await active.waitForText(draft, TIMEOUT);

      await active.sendHexBytes(["1b", "5b", "31", "31", "34", "3b", "39", "75"]);
      await active.waitForText(
        "submit or clear the draft before switching sessions",
        TIMEOUT,
      );
      const refused = stripAnsi(await active.capturePane());
      expect(refused).toContain(draft);
      expect(refused).not.toContain("Sessions");
      expect(gateway.requests).toHaveLength(1);

      await active.sendKeys("C-u");
      await active.waitForPane(
        (pane) => hasEmptyComposer(stripAnsi(pane)),
        TIMEOUT,
      );
      await active.sendHexBytes(["1b", "5b", "31", "31", "34", "3b", "39", "75"]);
      await active.waitForPane(
        (pane) => stripAnsi(pane).includes("Sessions"),
        TIMEOUT,
      );
      await active.sendKeys("Escape");
      await waitForSessionPickerClosed(active);

      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O viewer preserves hidden composer input while Ctrl-X stays inert",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-input-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const firstDone = "CTRL_O_INPUT_FIRST_DONE";
    const followUpDone = "CTRL_O_INPUT_FOLLOW_UP_DONE";
    const fullViewDraft = "CTRL_O_FULL_VIEW_COMPOSER_DRAFT";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const gateway = startFakeGateway([
      fakeGatewayFinalText(firstDone),
      fakeGatewayFinalText(followUpDone),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Start the prepared Ctrl-O input check.");
      await active.waitForText(firstDone, TIMEOUT);
      await active.waitForComposer(TIMEOUT);

      await active.sendKeys("C-o");
      await Bun.sleep(250);
      await active.sendHexBytes(["18"]);
      await active.sendHexBytes(["1b", "5b", "31", "32", "30", "3b", "35", "75"]);
      await active.sendLiteralText(fullViewDraft);
      await Bun.sleep(150);
      const fullView = await active.capturePane();
      expect(fullView).toContain(firstDone);
      expect(fullView).not.toContain(fullViewDraft);
      expect(fullView).toContain("┃ Review · ←/→ switch · ctrl o close");
      await active.sendKeys("Escape");
      await active.waitForText(fullViewDraft, TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText(followUpDone, TIMEOUT);
      const followUpBody = gateway.requests[1]?.body ?? "";
      const messages = JSON.parse(followUpBody).prompt as Array<{
        role: string;
        content: Array<{ type: string; text?: string }>;
      }>;
      const finalUser = messages[messages.length - 1];
      expect(finalUser?.role).toBe("user");
      expect(finalUser?.content[0]?.text).toBe(fullViewDraft);
      const afterSubmit = await active.capturePane();
      expect(afterSubmit).toContain(firstDone);
      expect(afterSubmit).toContain(followUpDone);
      await Bun.sleep(250);
      const settledGrid = await active.capturePaneGrid();
      expect(
        settledGrid.filter((line) => line.trimStart().startsWith("auto · ")),
      ).toHaveLength(1);
      await active.waitForComposer(TIMEOUT);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-C leaves Ctrl-O before cancelling a streaming command",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-cancel-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o-cancel.fxtape");
    const streamMarker = "CTRL_O_CANCEL_STREAM";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const command = `sh -c 'while :; do printf "${streamMarker}\\n"; sleep 0.1; done'`;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-cancel-command", "terminal", { action: "exec", command }),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, gateway), FX_RECORD: tapePath },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared Ctrl-O cancellation check.");
      await active.waitForText(streamMarker, TIMEOUT);

      await active.sendKeys("C-o");
      await Bun.sleep(250);
      const enterAlternate = Buffer.from("\x1b[?1049h");
      const leaveAlternate = Buffer.from("\x1b[?1049l");
      const tapeBeforeCancel = readFileSync(tapePath);
      const enterOffset = tapeBeforeCancel.lastIndexOf(enterAlternate);
      expect(enterOffset).toBeGreaterThanOrEqual(0);

      await active.sendKeys("C-c");
      await Bun.sleep(250);

      const tape = readFileSync(tapePath);
      expect(tape.indexOf(leaveAlternate, enterOffset + enterAlternate.length)).toBeGreaterThan(
        enterOffset,
      );
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O keeps command output live while the alternate buffer is open",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-live-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const firstMarker = "CTRL_O_LIVE_HEAD";
    const tailMarker = "CTRL_O_LIVE_TAIL";
    const command = "sh -c 'printf \"CTRL_O_LIVE_HEAD\\n\"; sleep 1; printf \"CTRL_O_LIVE_TAIL\\n\"'";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-live-command", "terminal", { action: "exec", command }),
      fakeGatewayFinalText("CTRL_O_LIVE_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared command.");
      await active.waitForText(firstMarker, TIMEOUT);

      await active.sendKeys("C-o");
      await active.waitForText(tailMarker, TIMEOUT);
      const full = await active.capturePane();
      expect(full).toContain(firstMarker);
      expect(full).toContain(tailMarker);

      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);
      await active.waitForText("CTRL_O_LIVE_DONE", TIMEOUT);
      const restored = await active.capturePane();
      expect(restored).not.toContain("\ninput\n");
      expect(restored).not.toContain("\nresult\n");
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "streaming wheel input stays inline until Ctrl-O",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-stream-scroll-inline-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "stream-scroll.fxtape");
    const tracePath = join(root, "trace.log");
    const phaseTwoComplete = join(workspace, "phase-two.complete");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const lineMarker = "STREAM_SCROLL_INLINE";
    const doneMarker = "STREAM_SCROLL_INLINE_DONE";
    const command = `zsh -lc 'for i in {1..80}; do printf "${lineMarker} %03d\\n" "$i"; done; sleep 2; for i in {81..160}; do printf "${lineMarker} %03d\\n" "$i"; done; : > ${shellQuote(phaseTwoComplete)}'`;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("stream-scroll-handoff", "terminal", { action: "exec", command }),
      fakeGatewayFinalText(doneMarker),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "full_transcript,full_transcript_cache,input,scroll,frame_diff,frame_commit",
        },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared streaming command.");
      await active.waitForPane(
        (pane) =>
          pane.includes(`${lineMarker} 001`) &&
          /│ … [1-9]\d* lines more \(ctrl o to view\)/.test(pane),
        TIMEOUT,
      );
      const scrollActions = [
        ["1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d"],
        ["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"],
        ["1b", "5b", "35", "7e"],
        ["1b", "5b", "36", "7e"],
      ];
      const stressBytes: string[] = [];
      for (let cycle = 0; cycle < 25; cycle += 1) {
        for (const action of scrollActions) stressBytes.push(...action);
      }
      await active.sendHexBytes(stressBytes);
      await Bun.sleep(250);
      const inlineAfterWheel = (await active.capturePaneGrid()).join("\n");
      expect(inlineAfterWheel).not.toContain("Review · ←/→ switch · ctrl o close");
      expect(readFileSync(tapePath)).not.toContain(Buffer.from("\x1b[?1000h\x1b[?1006h"));
      expect(readFileSync(tracePath, "utf8")).not.toContain(
        "depth_transition from=inline to=review",
      );

      await active.sendKeys("C-o");
      await active.waitForText("┃ Review · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendHexBytes(["1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d"]);
      await waitForCondition(
        () => readFileSync(tracePath, "utf8").includes("unit=wheel rows=3"),
        "viewer wheel trace",
      );
      const readingBefore = await active.capturePaneGrid();
      expect(readingBefore.join("\n")).toContain("Review · ←/→ switch · ctrl o close");
      expect(readingBefore.join("\n")).toMatch(/\d+ more lines · → to expand/);

      await waitForCondition(() => existsSync(phaseTwoComplete), "second output phase");
      await waitForCondition(() => gateway.requests.length >= 2, "post-command gateway request");
      const readingAfter = await active.capturePaneGrid();
      const normalizeLiveMetadata = (grid: string[]) => grid.map((row) => {
        if (/^└ (?:Running|Ran) /.test(row)) return "<command status>";
        if (/^│  \d+ output lines$/.test(row)) return "<output count>";
        if (/^│  \d+ more lines · → to expand$/.test(row)) return "<fold count>";
        return row;
      });
      const normalizedBefore = normalizeLiveMetadata(readingBefore);
      const normalizedAfter = normalizeLiveMetadata(readingAfter);
      for (const [rowIndex, row] of normalizedBefore.entries()) {
        if (row !== "") expect(normalizedAfter[rowIndex]).toBe(row);
      }
      for (const index of [1, 2, 3]) {
        const marker = `│ ${lineMarker} ${String(index).padStart(3, "0")}`;
        expect(readingAfter.indexOf(marker)).toBe(readingBefore.indexOf(marker));
      }

      await active.sendKeys("Escape");
      await active.waitForPane(
        (pane) => pane.includes(doneMarker) && !pane.includes("┃ Review · ←/→ switch · ctrl o close"),
        TIMEOUT,
      );
      const scrollback = await waitForScrollback(active, doneMarker);
      expect(scrollback).toContain(`│ ${lineMarker} 001`);
      expect(countOccurrences(scrollback, `│ ${lineMarker} 001`)).toBe(1);
      expect(scrollback).toContain("│ … 155 lines more (ctrl o to view)");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
      active = null;

      const stdout = Buffer.concat(
        readTapeFrames(tapePath)
          .filter((frame) => frame.kind === 1)
          .map((frame) => frame.payload),
      ).toString("binary");
      expect(countOccurrences(stdout, "\x1b[?1000h")).toBe(1);
      expect(countOccurrences(stdout, "\x1b[?1006h")).toBe(1);
      expect(countOccurrences(stdout, "\x1b[?1000l")).toBe(2);
      expect(countOccurrences(stdout, "\x1b[?1006l")).toBe(2);
      expect(stdout).toContain("\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l");
      expect(countOccurrences(stdout, "\x1b[?1049h")).toBe(1);
      expect(countOccurrences(stdout, "\x1b[?1049l")).toBe(1);

      const replay = await runFx(["replay", tapePath, "--json"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O navigation during shell streaming preserves compact scrollback rows",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-navigation-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const lineCount = 200;
    const commandMarker = "CTRL_O_NAV_REPEAT";
    const doneMarker = "CTRL_O_NAVIGATION_DONE";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-navigation-command", "terminal", {
        action: "exec",
        command: `zsh -lc 'for i in {1..100}; do printf "${commandMarker} %05d\\n" "$i"; done; sleep 2; for i in {101..${lineCount}}; do printf "${commandMarker} %05d\\n" "$i"; done'`,
      }),
      fakeGatewayFinalText(doneMarker),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared streaming command.");
      await active.waitForPane(
        (pane) =>
          pane.includes(`${commandMarker} 00005`) &&
          /│ … [1-9]\d* lines more \(ctrl o to view\)/.test(pane),
        TIMEOUT,
      );

      await active.sendKeys("C-o");
      await active.sendHexBytes(
        Array.from({ length: 4 }, () => ["1b", "5b", "35", "7e"]).flat(),
      );
      await active.sendHexBytes(
        Array.from({ length: 4 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.sendKeys("Escape");

      const scrollback = await waitForScrollback(active, doneMarker);
      const missingOrDuplicate: string[] = [];
      for (let index = 1; index <= 5; index += 1) {
        const line = `│ ${commandMarker} ${String(index).padStart(5, "0")}`;
        const count = countOccurrences(scrollback, line);
        if (count !== 1) missingOrDuplicate.push(`${line}: ${count}`);
      }
      expect(missingOrDuplicate).toEqual([]);
      expect(scrollback).not.toContain(`│ ${commandMarker} 00006`);
      expect(scrollback).not.toContain(
        `│ ${commandMarker} ${String(lineCount).padStart(5, "0")}`,
      );
      expect(scrollback).toContain(
        `│ … ${lineCount - 5} lines more (ctrl o to view)`,
      );
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "an ask-user prompt takes over Ctrl-O and accepts its choice inline",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-question-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o-question.fxtape");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const commandMarker = "CTRL_O_QUESTION_COMMAND_RUNNING";
    const questionMarker = "CTRL_O_QUESTION_PROMPT";
    const doneMarker = "CTRL_O_QUESTION_DONE";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-question-command", "terminal", {
        action: "exec",
        command: `sh -c 'printf "${commandMarker}\\n"; sleep 1'`,
      }),
      fakeGatewayToolCall("ctrl-o-question", "ask_user_question", {
        questions: [
          {
            question: questionMarker,
            options: [
              { label: "A", description: "Select A." },
              { label: "B", description: "Select B." },
            ],
          },
        ],
      }),
      fakeGatewayFinalText(doneMarker),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, gateway), FX_RECORD: tapePath },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared command and ask the prepared question.");
      await active.waitForText(commandMarker, TIMEOUT);
      await active.sendKeys("C-o");
      await active.waitForText(questionMarker, TIMEOUT);

      const tape = readFileSync(tapePath);
      const questionOffset = tape.lastIndexOf(Buffer.from(questionMarker));
      expect(questionOffset).toBeGreaterThanOrEqual(0);
      expect(tape.lastIndexOf(Buffer.from("\x1b[?1049l"), questionOffset)).toBeGreaterThanOrEqual(0);

      await active.sendLiteralText("1");
      await active.sendKeys("Enter");
      await active.waitForText(doneMarker, TIMEOUT);
      const inline = await active.capturePane();
      expect(inline).toContain(doneMarker);
      expect(inline).toContain(`\n  1) ${questionMarker}`);
      expect(inline).not.toContain("Use numbers, Up/Down, or tab to choose");
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O preserves inline block spacing while expanding tool detail",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-spacing-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const beforeMarker = "CTRL_O_SPACING_BEFORE";
    const outputMarker = "CTRL_O_SPACING_OUTPUT";
    const afterMarker = "CTRL_O_SPACING_AFTER";
    const command = `printf '${outputMarker}\\n'`;
    const gateway = startFakeGateway([
      fakeGatewaySerializedToolCall(
        "ctrl-o-spacing-command",
        "terminal",
        JSON.stringify({ action: "exec", command }),
        beforeMarker,
      ),
      fakeGatewayFinalText(afterMarker),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 40,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared command.");
      await waitForScrollback(active, afterMarker);
      await active.waitForComposer(TIMEOUT);
      const compactGrid = await active.capturePaneGrid();
      const compactTool = compactGrid.findIndex((line) => line.includes("Ran "));
      if (compactTool < 0) {
        throw new Error(`missing compact tool rows:\n${compactGrid.join("\n")}`);
      }

      await active.sendKeys("C-o");
      const fullTranscript = await active.waitForPane(
        (pane) =>
          pane.includes(beforeMarker) &&
          pane.includes("1 tool call") &&
          pane.includes("Ran ") &&
          pane.includes("1 output line") &&
          pane.includes(outputMarker) &&
          pane.includes(afterMarker),
        TIMEOUT,
      );
      const grid = fullTranscript.replace(/\n$/, "").split("\n");
      const before = grid.findIndex((line) => line.includes(beforeMarker));
      const header = grid.findIndex((line) => line.includes("1 tool call"));
      const tool = grid.findIndex((line) => line.includes("Ran "));
      const metadata = grid.findIndex((line) => line.includes("1 output line"));
      const output = grid.findIndex((line) => line.trimStart().startsWith(`│ ${outputMarker}`));
      const after = grid.findIndex((line) => line.includes(afterMarker));
      if (
        before < 0 || header < 0 || tool < 0 ||
        metadata < 0 || output < 0 || after < 0
      ) {
        throw new Error(`missing full transcript rows:\n${grid.join("\n")}`);
      }
      expect(fullTranscript).not.toContain(
        "Permissions: Auto agent approved this request",
      );
      expect(header).toBe(before + 2);
      expect(tool).toBe(header + 1);
      expect(metadata).toBe(tool + 1);
      expect(output).toBe(metadata + 1);
      expect(after).toBe(output + 2);

      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);
      const restoredGrid = await active.waitForStableGrid(
        compactGrid,
        normalizeVolatileStatusRows,
        TIMEOUT,
      );
      expect(normalizeVolatileStatusRows(restoredGrid)).toEqual(
        normalizeVolatileStatusRows(compactGrid),
      );
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O restores a long Markdown transcript without replaying it into scrollback",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-markdown-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const doneMarker = "CTRL_O_STATIC_MARKDOWN_DONE";
    const markdown = [
      "# Ctrl-O Markdown",
      "",
      ...Array.from(
        { length: 6 },
        (_, index) => `Paragraph ${index + 1} contains enough text to force an inline transcript scroll while preserving Markdown rendering and the active footer rows.`,
      ),
      "",
      doneMarker,
    ].join("\n\n");
    const gateway = startFakeGateway([fakeGatewayFinalText(markdown)]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 12,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Return the prepared Markdown response.");
      await waitForScrollback(active, doneMarker);

      await active.sendKeys("C-o");
      await Bun.sleep(250);
      for (let index = 0; index < 12; index += 1) {
        await active.sendHexBytes(["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"]);
      }
      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);

      const restoredScrollback = await active.captureFullScrollback();
      expect(countOccurrences(restoredScrollback, doneMarker)).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O renders read_file results as readable content",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-read-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(
      join(workspace, "README.md"),
      "READ_RESULT_MARKER\n",
    );
    writeFileSync(stderrPath, "");

    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-read", "read_file", { path: "README.md" }),
      fakeGatewayFinalText("CTRL_O_READ_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Read the prepared file.");
      await waitForScrollback(active, "CTRL_O_READ_DONE");

      await active.sendKeys("C-o");
      await active.waitForText("READ_RESULT_MARKER", TIMEOUT);
      const review = await active.capturePane();
      expect(review).toContain("Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close");
      expect(review).toContain("1 line");
      expect(review).toContain("READ_RESULT_MARKER");
      expect(review).not.toContain("<path>");
      expect(review).not.toContain("<content>");
      expect(review).not.toContain("\\x0a");
      expect(review).not.toMatch(/^\s*input\s*$/m);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O expands each parallel read-only tool detail",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-parallel-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(join(workspace, "README.md"), "READ_FULL_DETAIL_MARKER\n");
    writeFileSync(join(workspace, "LIST_FULL_DETAIL_MARKER"), "");
    writeFileSync(stderrPath, "");

    const gateway = startFakeGateway([
      fakeGatewaySse([
        { type: "tool-call", toolCallId: "parallel-list", toolName: "list_files", input: { path: "." } },
        { type: "tool-call", toolCallId: "parallel-read", toolName: "read_file", input: { path: "README.md" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewayFinalText("PARALLEL_DETAIL_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared read-only tools.");
      await waitForScrollback(active, "PARALLEL_DETAIL_DONE");

      await active.sendKeys("C-o");
      await active.waitForText("LIST_FULL_DETAIL_MARKER", TIMEOUT);
      const firstDetail = await active.capturePane();
      expect(firstDetail).toContain("LIST_FULL_DETAIL_MARKER");
      expect(firstDetail).toContain("Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close");
      expect(firstDetail).not.toMatch(/^\s*input\s*$/m);

      await active.waitForText("READ_FULL_DETAIL_MARKER", TIMEOUT);
      const full = await active.capturePane();
      expect(full).toContain("READ_FULL_DETAIL_MARKER");
      expect(full).not.toMatch(/^\s*input\s*$/m);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a file approval takes over Ctrl-O and resolves back to the inline transcript",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-approval-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o-file-approval.fxtape");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({
        sandbox: "none",
        permission_mode: "ask",
        permission: {},
        maxxing_mode: "legacy",
      }),
    );
    writeFileSync(stderrPath, "");

    const priorSummary = "CTRL_O_FILE_PRIOR_SUMMARY";
    const priorCommand = "zsh -lc 'for i in {1..650}; do printf \"CTRL_O_FILE_FOLD_%04d: preserve full scrollback semantics\\n\" \"$i\"; done'";
    const fileContent = Array.from(
      { length: 80 },
      (_, index) => `handoff scrollback line ${String(index + 1).padStart(3, "0")}`,
    ).join("\\n");
    const finalReply = `${Array.from(
      { length: 80 },
      () => "The denied write remains visible while this streamed assistant response advances the compact transcript window.",
    ).join(" ")} CTRL_O_HANDOFF_DONE`;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-handoff-prior", "terminal", { action: "exec", command: priorCommand }),
      fakeGatewayFinalText(priorSummary),
      fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "ctrl-o-handoff-command",
          toolName: "terminal",
          input: {
            action: "exec",
            command: "sh -c 'sleep 5; printf \"CTRL_O_HANDOFF_READY\\n\"'",
          },
        },
        {
          type: "tool-call",
          toolCallId: "ctrl-o-handoff-write",
          toolName: "write_file",
          input: {
            path: "ctrl-o-handoff.txt",
            content: fileContent,
          },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewayFinalText(finalReply),
    ]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, gateway), FX_RECORD: tapePath },
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared folded output command.");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      const beforeHandoff = await waitForScrollback(active, priorSummary);
      expect(beforeHandoff).toContain("│ … 645 lines more (ctrl o to view)");
      expect(countOccurrences(beforeHandoff, priorSummary)).toBe(1);
      const compactOutputRows = beforeHandoff.match(/CTRL_O_FILE_FOLD_\d{4}/g) ?? [];
      expect(compactOutputRows).toHaveLength(5);
      expect(beforeHandoff).not.toContain("CTRL_O_FILE_FOLD_0006");
      expect(beforeHandoff).not.toContain("CTRL_O_FILE_FOLD_0650");
      for (const line of compactOutputRows) {
        expect(countOccurrences(beforeHandoff, line)).toBe(1);
      }

      await active.sendText("Run the prepared command and then write the file.");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      await active.waitForText("Running", TIMEOUT);
      await active.sendKeys("C-o");
      await Bun.sleep(150);
      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      await active.waitForText("Apply this change?", TIMEOUT);

      await active.sendKeys("3");
      await active.sendKeys("Enter");
      await active.waitForText("CTRL_O_HANDOFF_DONE", TIMEOUT);
      const scrollback = await active.captureFullScrollback();
      const inline = await active.capturePane();
      expect(inline).toContain("CTRL_O_HANDOFF_DONE");
      expect(inline).not.toContain("Apply this change?");
      expect(countOccurrences(scrollback, priorSummary)).toBe(1);
      for (const line of compactOutputRows) {
        const occurrences = countOccurrences(scrollback, line);
        expect(occurrences).toBeGreaterThanOrEqual(1);
        expect(occurrences).toBeLessThanOrEqual(2);
      }
      const tape = readFileSync(tapePath).toString("latin1");
      expect(countOccurrences(tape, "\x1b[?1049h")).toBe(1);
      expect(countOccurrences(tape, "\x1b[?1049l")).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
      passed = true;
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained Ctrl-O file-approval artifacts at ${root}`);
      }
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a shell approval takes over Ctrl-O and accepts its choice inline",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-shell-approval-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const gateway = startFakeGateway([
      async () => {
        await Bun.sleep(300);
        return fakeGatewayToolCall("ctrl-o-shell-approval", "terminal", {
          action: "exec",
          command: "sh -c 'printf \"CTRL_O_SHELL_APPROVAL_RAN\\n\"'",
        });
      },
      fakeGatewayFinalText("CTRL_O_SHELL_APPROVAL_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared shell command.");
      await active.sendKeys("C-o");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);

      await active.sendKeys("1");
      await active.sendKeys("Enter");
      await active.waitForText("CTRL_O_SHELL_APPROVAL_DONE", TIMEOUT);
      const inline = await active.capturePane();
      expect(inline).toContain("CTRL_O_SHELL_APPROVAL_DONE");
      expect(inline).not.toContain("Would you like to run the following command?");
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a shell approval handoff does not duplicate a long Ctrl-O transcript in scrollback",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-handoff-scrollback-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const actionTimeout = 8_000;
    const transcriptTimeout = 90_000;
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const bulletMarker = "CTRL_O_SCROLLBACK_BULLET_120";
    const codeMarker = "const CTRL_O_SCROLLBACK_FINAL_ZIG = true;";
    const markdownLines = ["# Ctrl-O scrollback handoff", ""];
    for (let index = 1; index <= 120; index += 1) {
      markdownLines.push(
        `- CTRL_O_SCROLLBACK_BULLET_${String(index).padStart(3, "0")} has enough prose to wrap across the terminal width and exercise the rendered Markdown tail.`,
      );
      if (index % 40 === 0) {
        markdownLines.push(
          "",
          "```zig",
          "const transcript = @import(\"transcript\");",
          "const renderer = @import(\"renderer\");",
          "const layout = @import(\"layout\");",
          "const writer = @import(\"writer\");",
          "const rows = 120;",
          "const stable = true;",
          "const active = false;",
          index === 120 ? codeMarker : `const CTRL_O_SCROLLBACK_CODE_${index} = true;`,
          "_ = transcript;",
          "_ = renderer;",
          "_ = layout;",
          "_ = writer;",
          "_ = rows;",
          "_ = stable;",
          "_ = active;",
          "```",
          "",
        );
      }
    }
    const markdown = markdownLines.join("\n");
    const streamedMarkdown = () => {
      const encoder = new TextEncoder();
      const chunks = Array.from(
        { length: Math.ceil(markdown.length / 240) },
        (_, index) => markdown.slice(index * 240, (index + 1) * 240),
      );
      return new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            for (const chunk of chunks) {
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: chunk })}\n\n`));
              await Bun.sleep(10);
            }
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
            })}\n\n`));
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
    };
    const gateway = startFakeGateway([
      streamedMarkdown,
      fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "ctrl-o-handoff-first",
          toolName: "terminal",
          input: {
            action: "exec",
            command: "sh -c 'touch ctrl-o-handoff-first; printf \"CTRL_O_HANDOFF_FIRST_RUNNING\\n\"; sleep 1; printf \"CTRL_O_HANDOFF_FIRST_DONE\\n\"'",
          },
        },
        {
          type: "tool-call",
          toolCallId: "ctrl-o-handoff-second",
          toolName: "terminal",
          input: {
            action: "exec",
            command: "touch ctrl-o-handoff-second && printf 'CTRL_O_HANDOFF_SECOND_DONE\\n'",
          },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewayFinalText("CTRL_O_HANDOFF_SCROLLBACK_DONE"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(actionTimeout);
      await active.sendText("Return the prepared Markdown response.");
      await waitForScrollback(active, "CTRL_O_SCROLLBACK_BULLET_004");

      await active.sendKeys("C-o");
      await Bun.sleep(150);
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", actionTimeout);
      await active.sendHexBytes(
        Array.from({ length: 20 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText(bulletMarker, transcriptTimeout);

      await active.sendText("Run the prepared two commands.");
      await active.waitForText("Would you like to run the following command?", actionTimeout);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      await active.waitForText("CTRL_O_HANDOFF_FIRST_RUNNING", actionTimeout);
      const beforeHandoff = await active.captureFullScrollback();
      expect(countOccurrences(beforeHandoff, bulletMarker)).toBe(1);
      expect(countOccurrences(beforeHandoff, codeMarker)).toBe(1);

      await active.sendKeys("C-o");
      await Bun.sleep(150);
      await active.waitForText("Would you like to run the following command?", actionTimeout);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      await waitForScrollback(active, "CTRL_O_HANDOFF_SCROLLBACK_DONE");
      await active.waitForPane(
        (pane) =>
          pane.includes("CTRL_O_HANDOFF_SCROLLBACK_DONE") &&
          !pane.includes("Streaming ("),
        actionTimeout,
      );
      const scrollback = await active.captureFullScrollback();

      expect(countOccurrences(scrollback, bulletMarker)).toBe(1);
      expect(countOccurrences(scrollback, codeMarker)).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(5_000)).toBe(true);
      active = null;
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O pressure preserves transcript and modal ownership under deterministic load",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-transcript-pressure-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "ctrl-o-pressure.fxtape");
    const seedPath = join(root, "seed.txt");
    const scrollbackPath = join(root, "scrollback.txt");
    const ansiScrollbackPath = join(root, "scrollback.ansi.txt");
    const releasePath = join(workspace, ".ctrl-o-pressure-release");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");
    writeFileSync(seedPath, "9767\n");

    const setupSentinel = "CTRL_O_PRESSURE_SETUP_DONE";
    const finalSentinel = "CTRL_O_PRESSURE_FINAL_DONE";
    const assistantHead = "CTRL_O_PRESSURE_ASSISTANT_001";
    const assistantTail = "CTRL_O_PRESSURE_ASSISTANT_048";
    const setupCompactLine = "CTRL_O_PRESSURE_SETUP_OUTPUT_005";
    const setupFullLine = "CTRL_O_PRESSURE_SETUP_OUTPUT_070";
    const activeStart = "CTRL_O_PRESSURE_ACTIVE_START";
    const streamPrefix = "CTRL_O_PRESSURE_STREAM_";
    const streamGate = "CTRL_O_PRESSURE_STREAM_GATE";
    const activeDone = "CTRL_O_PRESSURE_ACTIVE_DONE";
    const questionMarker = "CTRL_O_PRESSURE_QUESTION";
    const questionAnswerInstruction = "Enter Answer";
    const questionCancelInstruction = "Esc Cancel";
    const composerProbe = "CTRL_O_PRESSURE_COMPOSER_READY";
    const setupCommand =
      "awk 'BEGIN { for (i = 1; i <= 72; i++) printf \"CTRL_O_PRESSURE_SETUP_OUTPUT_%03d: retained command history\\n\", i }'";
    const assistantHistory = Array.from(
      { length: 48 },
      (_, index) =>
        `CTRL_O_PRESSURE_ASSISTANT_${String(index + 1).padStart(3, "0")}: retained assistant history`,
    ).join("\n");
    const activeCommand = [
      "sh -c '",
      `printf \"${activeStart}\\n\"; `,
      `i=1; while [ \"$i\" -le 6 ]; do printf \"${streamPrefix}%03d\\n\" \"$i\"; i=$((i + 1)); done; `,
      `printf \"${streamGate}\\n\"; `,
      "while [ ! -f .ctrl-o-pressure-release ]; do sleep 0.02; done; ",
      `while [ \"$i\" -le 18 ]; do printf \"${streamPrefix}%03d\\n\" \"$i\"; i=$((i + 1)); done; `,
      `printf \"${activeDone}\\n\"'`,
    ].join("");
    const fileContent = Array.from(
      { length: 96 },
      (_, index) =>
        `CTRL_O_PRESSURE_FILE_${String(index + 1).padStart(3, "0")}: pending review content`,
    ).join("\n");

    let releaseQuestion!: () => void;
    const questionGate = new Promise<void>((resolve) => {
      releaseQuestion = resolve;
    });
    const gatedQuestion = async () => {
      await questionGate;
      return fakeGatewayToolCall("ctrl-o-pressure-question", "ask_user_question", {
        questions: [
          {
            question: questionMarker,
            options: [
              { label: "Continue", description: "Finish the deterministic pressure flow." },
              { label: "Stop", description: "Stop the deterministic pressure flow." },
            ],
          },
        ],
      });
    };
    const gateway = startFakeGateway([
      fakeGatewayToolCall("ctrl-o-pressure-setup", "terminal", {
        action: "exec",
        command: setupCommand,
      }),
      fakeGatewayFinalText(`${assistantHistory}\n${setupSentinel}`),
      fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "ctrl-o-pressure-command",
          toolName: "terminal",
          input: { action: "exec", command: activeCommand },
        },
        {
          type: "tool-call",
          toolCallId: "ctrl-o-pressure-write",
          toolName: "write_file",
          input: { path: "ctrl-o-pressure.txt", content: fileContent },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      gatedQuestion,
      fakeGatewayFinalText(finalSentinel),
    ]);

    const tapeText = () => existsSync(tapePath) ? readFileSync(tapePath).toString("latin1") : "";
    const alternateDepthAt = (tape: string, end = tape.length): number => {
      let depth = 0;
      for (const transition of tape.slice(0, end).matchAll(/\x1b\[\?1049([hl])/g)) {
        depth += transition[1] === "h" ? 1 : -1;
      }
      return depth;
    };
    const pressureRows = (scrollback: string): string[] =>
      scrollback.split("\n").filter((line) =>
        line.includes("CTRL_O_PRESSURE_ASSISTANT_") ||
        line.includes(setupSentinel) ||
        line.includes("CTRL_O_PRESSURE_SETUP_OUTPUT_") ||
        line.includes(activeStart) ||
        line.includes(streamPrefix) ||
        line.includes(streamGate)
      ).map((line) => line.trimEnd());

    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, gateway),
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
        stderrPath,
        width: 104,
        height: 28,
        remainOnExit: true,
      });
      await active.waitForComposer(TIMEOUT);

      await active.sendText("Build the prepared pressure history.");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      const setupScrollback = await waitForScrollbackMarkers(active, [
        assistantHead,
        assistantTail,
        setupCompactLine,
        setupSentinel,
      ]);
      expect(setupScrollback).toContain(assistantHead);
      expect(setupScrollback).toContain(assistantTail);
      expect(setupScrollback).toContain(setupCompactLine);
      expect(setupScrollback).not.toContain(setupFullLine);
      expect(setupScrollback).toContain("│ … 67 lines more (ctrl o to view)");

      await active.sendText("Run the prepared streaming command and file review.");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      await active.waitForPane(
        (pane) =>
          pane.includes(`${streamPrefix}004`) &&
          /│ … [1-9]\d* lines more \(ctrl o to view\)/.test(pane),
        TIMEOUT,
      );
      const compactRowsBeforeNavigation = pressureRows(await active.captureFullScrollback());

      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 1,
        "Ctrl-O to enter the alternate screen",
      );
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendHexBytes(["1b", "5b", "36", "7e"]);
      const tailViewport = await active.waitForText(streamGate, TIMEOUT);
      expect(tailViewport).toContain(streamGate);

      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      const pageUpViewport = await active.waitForPane(
        (pane) => pane !== tailViewport && pane.includes("CTRL_O_PRESSURE_ASSISTANT_"),
        TIMEOUT,
      );
      expect(pageUpViewport).not.toEqual(tailViewport);

      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      await active.sendHexBytes(["1b", "5b", "35", "7e"]);
      const priorCommandViewport = await active.waitForPane(
        (pane) =>
          pane !== pageUpViewport &&
          pane.includes("CTRL_O_PRESSURE_SETUP_OUTPUT_055"),
        TIMEOUT,
      );
      expect(priorCommandViewport).not.toEqual(pageUpViewport);

      for (let index = 0; index < 2; index += 1) {
        await active.sendHexBytes(["1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d"]);
      }
      await active.waitForPane(
        (pane) => pane !== priorCommandViewport && pane.includes(setupFullLine),
        TIMEOUT,
      );
      for (let index = 0; index < 6; index += 1) {
        await active.sendHexBytes(["1b", "5b", "36", "7e"]);
      }
      const pageDownViewport = await active.waitForPane(
        (pane) => pane !== priorCommandViewport && pane.includes(streamGate),
        TIMEOUT,
      );
      expect(pageDownViewport).not.toEqual(priorCommandViewport);

      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 0,
        "Ctrl-O to restore compact history",
      );
      expect(pressureRows(await active.captureFullScrollback())).toEqual(
        compactRowsBeforeNavigation,
      );

      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 1,
        "the repeated Ctrl-O entry",
      );
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 0,
        "the repeated Ctrl-O exit",
      );
      expect(pressureRows(await active.captureFullScrollback())).toEqual(
        compactRowsBeforeNavigation,
      );

      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 1,
        "Ctrl-O to reopen before the file handoff",
      );
      writeFileSync(releasePath, "release\n");
      await waitForCondition(
        () => tapeText().includes(activeDone),
        "the gated command stream to finish",
      );
      await active.waitForText("Apply this change?", TIMEOUT);
      const fileApprovalTape = tapeText();
      const fileApprovalOffset = fileApprovalTape.lastIndexOf("Apply this change?");
      expect(fileApprovalOffset).toBeGreaterThanOrEqual(0);
      expect(alternateDepthAt(fileApprovalTape, fileApprovalOffset)).toBe(1);

      await active.sendKeys("3");
      await active.sendKeys("Enter");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 0,
        "file approval rejection to restore inline ownership",
      );
      const afterFileRejection = await active.waitForPane(
        (pane) =>
          pane.includes(activeStart) &&
          pane.includes("│ … 16 lines more (ctrl o to view)") &&
          !pane.includes("Apply this change?"),
        TIMEOUT,
      );
      expect(afterFileRejection).not.toContain(questionMarker);
      expect(existsSync(join(workspace, "ctrl-o-pressure.txt"))).toBe(false);

      await active.sendKeys("C-o");
      await waitForCondition(
        () => alternateDepthAt(tapeText()) === 1,
        "Ctrl-O to reopen before the question handoff",
      );
      releaseQuestion();
      await active.waitForText(questionMarker, TIMEOUT);
      const questionTape = tapeText();
      const questionOffset = questionTape.lastIndexOf(questionMarker);
      expect(questionOffset).toBeGreaterThanOrEqual(0);
      expect(alternateDepthAt(questionTape, questionOffset)).toBe(0);
      const questionPane = await active.capturePane();
      expect(questionPane).toContain(questionAnswerInstruction);
      expect(questionPane).toContain(questionCancelInstruction);
      expect(questionPane).not.toContain("Apply this change?");

      await active.sendLiteralText("1");
      await active.sendKeys("Enter");
      const finalScrollback = await waitForScrollback(active, finalSentinel);
      const finalPane = await active.capturePane();
      expect(finalScrollback).toContain(assistantHead);
      expect(finalScrollback).toContain(assistantTail);
      expect(finalScrollback).toContain(setupCompactLine);
      expect(finalScrollback).not.toContain(setupFullLine);
      expect(finalScrollback).toContain(`\n  1) ${questionMarker}`);
      expect(countOccurrences(finalScrollback, setupSentinel)).toBe(1);
      expect(countOccurrences(finalScrollback, finalSentinel)).toBe(1);
      for (let index = 1; index <= 4; index += 1) {
        const outputRow = `│ ${streamPrefix}${String(index).padStart(3, "0")}`;
        expect(countOccurrences(finalScrollback, outputRow)).toBe(1);
      }
      for (let index = 5; index <= 18; index += 1) {
        const outputRow = `│ ${streamPrefix}${String(index).padStart(3, "0")}`;
        expect(countOccurrences(finalScrollback, outputRow)).toBe(0);
      }
      expect(countOccurrences(finalScrollback, `│ ${activeStart}`)).toBe(1);
      expect(countOccurrences(finalScrollback, `│ ${streamGate}`)).toBe(0);
      expect(countOccurrences(finalScrollback, `│ ${activeDone}`)).toBe(0);
      expect(finalScrollback).toContain("│ … 16 lines more (ctrl o to view)");
      expect(finalPane).not.toContain("Apply this change?");
      expect(finalPane).not.toContain(questionAnswerInstruction);
      expect(finalPane).not.toContain(questionCancelInstruction);
      expect(gateway.requests).toHaveLength(5);

      await active.sendLiteralText(composerProbe);
      await active.waitForText(composerProbe, TIMEOUT);
      await active.sendKeys("C-u");
      const clearedComposer = await active.waitForPane(
        (pane) =>
          pane.includes(finalSentinel) &&
          hasEmptyComposer(pane) &&
          !pane.includes(composerProbe),
        TIMEOUT,
      );
      expect(clearedComposer).not.toContain("Apply this change?");
      expect(clearedComposer).not.toContain(questionAnswerInstruction);
      expect(clearedComposer).not.toContain(questionCancelInstruction);

      const finalTape = tapeText();
      let alternateDepth = 0;
      let maximumAlternateDepth = 0;
      let alternateEnters = 0;
      let alternateLeaves = 0;
      for (const transition of finalTape.matchAll(/\x1b\[\?1049([hl])/g)) {
        if (transition[1] === "h") {
          alternateDepth += 1;
          alternateEnters += 1;
          maximumAlternateDepth = Math.max(maximumAlternateDepth, alternateDepth);
        } else {
          alternateDepth -= 1;
          alternateLeaves += 1;
        }
        expect(alternateDepth).toBeGreaterThanOrEqual(0);
      }
      expect(maximumAlternateDepth).toBe(1);
      expect(alternateEnters).toBeGreaterThanOrEqual(4);
      expect(alternateLeaves).toBe(alternateEnters);
      expect(alternateDepth).toBe(0);

      await active.sendText("/quit");
      await waitForCondition(
        () => active?.paneStatus().dead === true,
        "Fx to exit after /quit",
      );
      expect(paneExitMatches(active.paneStatus(), 0)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(statSync(tapePath).size).toBeGreaterThan(0);

      const replayFrames = await runFx(["replay", tapePath, "--frames"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replayFrames.code).toBe(0);
      expect(replayFrames.stderr).toBe("");
      expect(replayFrames.stdout).toContain(setupSentinel);
      expect(replayFrames.stdout).toContain(finalSentinel);
      expect(replayFrames.stdout).toContain(composerProbe);

      const replayFinalGrid = await runFx(["replay", tapePath], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replayFinalGrid.code).toBe(0);
      expect(replayFinalGrid.stderr).toBe("");
      expect(replayFinalGrid.stdout).toContain(finalSentinel);
      expect(replayFinalGrid.stdout).not.toContain("Apply this change?");
      expect(replayFinalGrid.stdout).not.toContain(questionAnswerInstruction);
      expect(replayFinalGrid.stdout).not.toContain(questionCancelInstruction);
      passed = true;
    } finally {
      releaseQuestion();
      if (active) {
        try {
          writeFileSync(scrollbackPath, await active.captureFullScrollback());
          writeFileSync(ansiScrollbackPath, await active.captureFullScrollbackEscapes());
        } catch {}
        await active.kill();
      }
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained Ctrl-O pressure artifacts at ${root}`);
      }
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "contended startup resume stays non-interactive and recovers after release",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-contended-resume-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const ownerStderrPath = join(root, "owner-stderr.log");
    const contenderStderrPath = join(root, "contender-stderr.log");
    const retryStderrPath = join(root, "retry-stderr.log");
    const contenderTapePath = join(root, "contender.fxtape");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const savedMarker = "CONTENDED_RESUME_SAVED_MARKER";
    const ownerGateway = startFakeGateway([fakeGatewayFinalText(savedMarker)]);
    const retryGateway = startFakeGateway([]);
    let owner: TmuxSession | null = null;
    let contender: TmuxSession | null = null;
    let retry: TmuxSession | null = null;
    let passed = false;

    try {
      writeFileSync(ownerStderrPath, "");
      owner = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, ownerGateway),
        stderrPath: ownerStderrPath,
      });
      await owner.waitForComposer(TIMEOUT);
      await owner.sendText("Save the contended resume fixture.");
      await owner.waitForText(savedMarker, TIMEOUT);
      expect(owner.isPaneAlive()).toBe(true);

      writeFileSync(contenderStderrPath, "");
      contender = await TmuxSession.create({
        cmd: `${FX_BIN} --resume`,
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, ownerGateway),
          FX_RECORD: contenderTapePath,
          FX_RECORD_INPUT: "1",
        },
        stderrPath: contenderStderrPath,
        remainOnExit: true,
      });
      await contender.sendLiteralText("/");
      await contender.sendLiteralText("/");
      await waitForCondition(
        () => contender?.paneStatus().dead === true,
        "contended resume to exit",
      );

      expect(paneExitMatches(contender.paneStatus(), 1)).toBe(true);
      expect(readFileSync(contenderStderrPath, "utf8")).toBe(
        "fx: another Fx process may be using this session (running or suspended); check other terminals or run jobs, then use fg or quit that process\n",
      );
      expect(owner.isPaneAlive()).toBe(true);
      const contenderScrollback = await contender.captureFullScrollback();
      expect(contenderScrollback).not.toContain("❯");
      expect(contenderScrollback).not.toContain("┃");
      expect(contenderScrollback).not.toContain("show available slash commands");
      const contenderReplay = await runFx(["replay", contenderTapePath, "--frames"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(contenderReplay.code).toBe(0);
      expect(contenderReplay.stderr).toBe("");
      expect(contenderReplay.stdout).not.toContain("❯");
      expect(contenderReplay.stdout).not.toContain("┃");
      expect(contenderReplay.stdout).not.toContain("show available slash commands");
      const contenderFrames = readTapeFrames(contenderTapePath);
      const contenderStdout = Buffer.concat(
        contenderFrames.filter((frame) => frame.kind === 1).map((frame) => frame.payload),
      ).toString("binary");
      expect(contenderStdout).not.toContain("\x1b[?2026h");
      expect(contenderFrames.filter((frame) => frame.kind === 2)).toHaveLength(0);

      await owner.sendText("/quit");
      expect(await owner.waitForSessionEnd()).toBe(true);
      await owner.kill();
      owner = null;

      writeFileSync(retryStderrPath, "");
      retry = await TmuxSession.create({
        cmd: `${FX_BIN} --resume`,
        cwd: workspaceRoot,
        env: gatewayEnv(home, retryGateway),
        stderrPath: retryStderrPath,
      });
      await retry.waitForComposer(TIMEOUT);
      const resumedScrollback = await waitForScrollback(retry, savedMarker);
      expect(resumedScrollback).toContain(savedMarker);
      const composerRows = (await retry.capturePaneGrid()).filter(isEmptyComposerLine);
      expect(composerRows).toHaveLength(1);

      await retry.sendLiteralText("/");
      await retry.waitForText("show available slash commands", TIMEOUT);
      await retry.sendLiteralText("/");
      await retry.waitForPane(
        (pane) =>
          pane.split("\n").some((row) => /^(?:┃|❯) \/\/$/.test(row)) &&
          !pane.includes("show available slash commands"),
        TIMEOUT,
      );
      expect(retry.isPaneAlive()).toBe(true);
      await retry.sendKeys("C-u");
      await retry.sendText("/quit");
      expect(await retry.waitForSessionEnd()).toBe(true);
      expect(readFileSync(retryStderrPath, "utf8")).toBe("");
      await retry.kill();
      retry = null;
      passed = true;
    } finally {
      if (owner) await owner.kill();
      if (contender) await contender.kill();
      if (retry) await retry.kill();
      ownerGateway.stop();
      retryGateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained contended resume artifacts at ${root}`);
      }
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "interactive resume shows session contention and retries the preserved selection",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-interactive-contention-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const ownerStderrPath = join(root, "owner-stderr.log");
    const contenderStderrPath = join(root, "contender-stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const savedMarker = "INTERACTIVE_CONTENTION_SAVED_MARKER";
    const savedTitle = "Save the interactive contention fixture.";
    const ownerGateway = startFakeGateway([fakeGatewayFinalText(savedMarker)]);
    const contenderGateway = startFakeGateway([]);
    let owner: TmuxSession | null = null;
    let contender: TmuxSession | null = null;

    try {
      writeFileSync(ownerStderrPath, "");
      owner = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, ownerGateway),
        stderrPath: ownerStderrPath,
        width: 100,
        height: 30,
      });
      await owner.waitForComposer(TIMEOUT);
      await owner.sendText(savedTitle);
      await owner.waitForText(savedMarker, TIMEOUT);

      writeFileSync(contenderStderrPath, "");
      contender = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, contenderGateway),
        stderrPath: contenderStderrPath,
        width: 100,
        height: 30,
      });
      await contender.waitForComposer(TIMEOUT);
      await contender.sendText("/resume");
      await waitForSessionPicker(contender);
      await contender.waitForText(savedTitle, TIMEOUT);
      const contentionStartedAt = Date.now();
      await contender.sendKeys("Enter");
      await contender.waitForPane(
        (pane) => stripAnsi(pane).includes(
          "This session is open in another Fx. Close it there, then press Enter to retry.",
        ),
        1_000,
      );
      expect(Date.now() - contentionStartedAt).toBeLessThan(1_000);

      const contendedPicker = stripAnsi(await contender.capturePane());
      expect(contendedPicker).toContain(savedTitle);
      expect(contendedPicker).toContain(
        "This session is open in another Fx. Close it there, then press Enter to retry.",
      );
      expect(contendedPicker).not.toContain("SessionBusy");
      const contendedEntries = visibleSessionPickerEntries(
        await contender.capturePaneEscapes(),
      );
      expect(contendedEntries).toHaveLength(1);
      expect(contendedEntries[0]!.selected).toBe(true);
      expect(owner.isPaneAlive()).toBe(true);
      expect(contender.isPaneAlive()).toBe(true);
      expect(readFileSync(ownerStderrPath, "utf8")).toBe("");
      expect(readFileSync(contenderStderrPath, "utf8")).toBe("");

      await owner.sendText("/quit");
      expect(await owner.waitForSessionEnd()).toBe(true);
      await owner.kill();
      owner = null;

      await contender.sendKeys("Enter");
      const resumed = await waitForScrollback(contender, savedMarker);
      expect(resumed).toContain(`● Session resumed: ${savedTitle}`);
      expect(resumed).toContain(savedMarker);
      expect(resumed).not.toContain("SessionBusy");
      await waitForSessionPickerClosed(contender);
      expect(contender.isPaneAlive()).toBe(true);
      expect(readFileSync(contenderStderrPath, "utf8")).toBe("");

      await contender.sendText("/quit");
      expect(await contender.waitForSessionEnd()).toBe(true);
      await contender.kill();
      contender = null;
    } finally {
      if (owner) await owner.kill();
      if (contender) await contender.kill();
      ownerGateway.stop();
      contenderGateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "context-deferred scoped tools remain deferred after resume",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-resume-deferred-tools-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const nested = join(workspace, "nested");
    const liveStderrPath = join(root, "live-stderr.log");
    const resumeStderrPath = join(root, "resume-stderr.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(nested, { recursive: true });
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(join(workspace, "AGENTS.md"), "DEFERRED_TOOL_ROOT_SCOPE\n");
    writeFileSync(join(nested, "AGENTS.md"), "DEFERRED_TOOL_NESTED_SCOPE\n");
    writeFileSync(join(nested, "input.txt"), "deferred tool payload\n");
    writeFileSync(liveStderrPath, "");
    writeFileSync(resumeStderrPath, "");

    const workspaceRoot = realpathSync(workspace);
    const command = "printf 'effectful payload\\n' > output.txt";
    const failureCommand = "printf 'ordinary-failure-control\\n' >&2; exit 7";
    const finalMarker = "DEFERRED_TOOL_RESUME_COMPLETE";
    const gateway = startFakeGateway([
      fakeGatewaySse([
        { type: "tool-input-start", id: "deferred-read", toolName: "read_file" },
        {
          type: "tool-input-delta",
          id: "deferred-read",
          delta: JSON.stringify({ path: "nested/input.txt" }),
        },
        { type: "tool-input-end", id: "deferred-read" },
        { type: "tool-input-start", id: "deferred-command", toolName: "terminal" },
        {
          type: "tool-input-delta",
          id: "deferred-command",
          delta: JSON.stringify({ action: "exec", command, cwd: "nested" }),
        },
        { type: "tool-input-end", id: "deferred-command" },
        {
          type: "tool-call",
          toolCallId: "deferred-read",
          toolName: "read_file",
          input: { path: "nested/input.txt" },
        },
        {
          type: "tool-call",
          toolCallId: "deferred-command",
          toolName: "terminal",
          input: { action: "exec", command, cwd: "nested" },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "reissued-read",
          toolName: "read_file",
          input: { path: "nested/input.txt" },
        },
        {
          type: "tool-call",
          toolCallId: "reissued-command",
          toolName: "terminal",
          input: { action: "exec", command, cwd: "nested" },
        },
        {
          type: "tool-call",
          toolCallId: "ordinary-failure",
          toolName: "terminal",
          input: { action: "exec", command: failureCommand },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      fakeGatewayFinalText(finalMarker),
    ]);
    const resumeGateway = startFakeGateway([]);
    let active: TmuxSession | null = null;

    function expectDeferredPresentation(scrollback: string): void {
      expect(scrollback).toContain(`↻ Context updated ${command}`);
      expect(countOccurrences(scrollback, "Context updated")).toBe(1);
      expect(scrollback).not.toContain("Not executed");
      expect(scrollback).not.toContain("● Failed nested/input.txt");
      expect(scrollback).not.toContain(`● Failed ${command}`);
      expect(scrollback).toContain("● Read nested/input.txt");
      expect(scrollback).toContain(`● Ran ${command}`);
      expect(scrollback).toContain(`● Ran ${failureCommand}`);
      expect(scrollback).toContain("│ exit code 7");
    }

    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, gateway),
        stderrPath: liveStderrPath,
        width: 120,
        height: 60,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText(
        "Read nested/input.txt, write nested/output.txt from that directory, and exercise the failure control.",
      );
      await waitForScrollback(active, finalMarker);
      await waitForCondition(
        () => gateway.requests.length === 3,
        "three scoped-tool completion requests",
      );
      const liveScrollback = await active.captureFullScrollback();
      expectDeferredPresentation(liveScrollback);
      expect(liveScrollback).toContain("│ ordinary-failure-control");
      expect(readFileSync(liveStderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      active = await TmuxSession.create({
        cmd: `${FX_BIN} resume last`,
        cwd: workspaceRoot,
        env: gatewayEnv(home, resumeGateway),
        stderrPath: resumeStderrPath,
        width: 120,
        height: 60,
      });
      await waitForScrollback(active, finalMarker);
      expectDeferredPresentation(await active.captureFullScrollback());

      await active.sendKeys("C-o");
      const detail = await active.waitForPane(
        (pane) =>
          pane.includes(`↻ Context updated ${command}`) &&
          pane.includes("ordinary-failure-control"),
        TIMEOUT,
      );
      expect(countOccurrences(detail, "Context updated")).toBe(1);
      expect(detail).not.toContain("Not executed");
      expect(detail).not.toContain('{"path":"nested/input.txt"}');
      expect(detail).not.toContain(JSON.stringify({ command, cwd: "nested" }));
      expect(detail).toContain(failureCommand);
      expect(detail).toContain("1 deferred");
      expect(detail).toContain("1 failed");
      expect(readFileSync(resumeStderrPath, "utf8")).toBe("");

      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      gateway.stop();
      resumeGateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "new and resumed sessions drop kill-ring and large-paste backing state",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-input-reset-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    writeFileSync(stderrPath, "");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("SESSION_INPUT_RESET_SAVED"),
      fakeGatewayFinalText("SESSION_INPUT_RESET_NEW_OK"),
      fakeGatewayFinalText("SESSION_INPUT_RESET_RESUME_OK"),
    ]);
    let active: TmuxSession | null = null;

    async function seedTransientDraft(marker: string): Promise<void> {
      if (!active) throw new Error("session is not active");
      await active.pasteText(`${marker}_${"x".repeat(1200)}`);
      await active.waitForPane((pane) => pane.includes("[Pasted text #1"), TIMEOUT);
      await active.sendKeys("C-u");
      await active.waitForPane((pane) => hasEmptyComposer(stripAnsi(pane)), TIMEOUT);
    }

    async function proveReset(responseMarker: string, requestIndex: number): Promise<void> {
      if (!active) throw new Error("session is not active");
      await active.sendKeys("C-y");
      await Bun.sleep(100);
      expect(stripAnsi(await active.capturePane())).not.toContain("[Pasted text #1");

      const literalPlaceholder = "[Pasted text #1, 1 line]";
      await active.sendText(literalPlaceholder);
      await active.waitForText(responseMarker, TIMEOUT);
      expect(gateway.requests[requestIndex]?.body).toContain(literalPlaceholder);
      expect(gateway.requests[requestIndex]?.body).not.toContain("STALE_SESSION_DRAFT");
    }

    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save a session for transient input reset.");
      await active.waitForText("SESSION_INPUT_RESET_SAVED", TIMEOUT);

      await seedTransientDraft("STALE_SESSION_DRAFT_NEW");
      await active.sendText("/new");
      await active.waitForPane((pane) => hasEmptyComposer(stripAnsi(pane)), TIMEOUT);
      await proveReset("SESSION_INPUT_RESET_NEW_OK", 1);

      await seedTransientDraft("STALE_SESSION_DRAFT_RESUME");
      await active.sendText("/resume");
      await waitForSessionPicker(active);
      await active.sendKeys("Enter");
      await waitForSessionPickerClosed(active);
      await proveReset("SESSION_INPUT_RESET_RESUME_OK", 2);

      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "graceful exit prints an exact resume command",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-exit-handoff-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const binDir = join(root, "bin");
    const stderrPath = join(root, "stderr.log");
    const resumedStderrPath = join(root, "resumed-stderr.log");
    const tapePath = join(root, "session.fxtape");
    const marker = "EXIT_HANDOFF_SAVED_HISTORY";
    mkdirSync(home);
    mkdirSync(workspace);
    mkdirSync(binDir);
    symlinkSync(FX_BIN, join(binDir, "fx"));
    writeFileSync(stderrPath, "");
    writeFileSync(resumedStderrPath, "");
    const initialGateway = startFakeGateway([fakeGatewayFinalText(marker)]);
    const resumedGateway = startFakeGateway([]);
    const path = `${binDir}:${process.env.PATH ?? ""}`;
    let active: TmuxSession | null = null;
    let passed = false;

    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, initialGateway),
          PATH: path,
          FX_RECORD: tapePath,
          FX_THEME: "dark",
        },
        stderrPath,
        width: 120,
        height: 32,
        remainOnExit: true,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save this conversation for the exit handoff.");
      await active.waitForText(marker, TIMEOUT);
      const sessionId = sessionIdFromHome(home);

      await active.sendText("/quit");
      await waitForCondition(
        () => active?.paneStatus().dead === true,
        "the graceful exit pane to stop",
      );
      expect(paneExitMatches(active.paneStatus(), 0)).toBe(true);
      const scrollback = stripAnsi(await active.captureFullScrollback());
      const ansiScrollback = await active.captureFullScrollbackEscapes();
      const expected = `Continue session with: fx --resume ${sessionId}`;
      expect(scrollback).toContain(expected);
      expect(scrollback).not.toContain("To continue this session, run:");
      expect(ansiScrollback).toContain(`\x1b[38;5;245m${expected}\x1b[39m`);
      expect(countOccurrences(scrollback, expected)).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readFileSync(tapePath).includes(Buffer.from(expected))).toBe(
        false,
      );
      const handoffLine = scrollback
        .split("\n")
        .map((line) => line.trim())
        .find((line) => line === expected);
      const printedCommand = handoffLine?.slice("Continue session with: ".length);
      expect(printedCommand).toBe(`fx --resume ${sessionId}`);

      await active.kill();
      active = await TmuxSession.create({
        cmd: printedCommand!,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, resumedGateway),
          PATH: path,
        },
        stderrPath: resumedStderrPath,
        width: 120,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      const resumed = stripAnsi(await waitForScrollback(active, marker));
      expect(resumed).toContain(marker);
      expect(resumedGateway.requests).toHaveLength(0);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      passed = true;
    } finally {
      if (active) await active.kill();
      initialGateway.stop();
      resumedGateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained exit handoff artifacts at ${root}`);
      }
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "closing the startup resume picker starts a writable fresh session",
  async () => {
    const root = realpathSync(
      mkdtempSync(join(tmpdir(), "fx-tui-resume-picker-cancel-")),
    );
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const marker = "fresh session after closing the resume picker";
    const gateway = startFakeGateway([fakeGatewayFinalText(marker)]);
    let active: TmuxSession | null = null;
    let passed = false;

    try {
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} -r`,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, gateway),
        stderrPath,
      });
      const picker = stripAnsi(
        await active.waitForPane(
          (pane) =>
            pane.includes("Sessions 0") && pane.includes("No sessions found."),
          TIMEOUT,
        ),
      );
      expect(picker).toContain("Esc Close");

      await active.sendKeys("Escape");
      await waitForSessionPickerClosed(active);
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Start a fresh session after closing the picker.");
      await active.waitForText(marker, TIMEOUT);
      await waitForPersistedSessionMarker(home, marker);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.kill();
      active = null;
      passed = true;
    } finally {
      if (active) await active.kill();
      gateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained picker cancel artifacts at ${root}`);
      }
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "interactive resume aliases restore history and return to a live composer",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-resume-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    let active: TmuxSession | null = null;
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];

    try {
      const initialMarker = "distinctive saved resume history";
      const initialGateway = startFakeGateway([
        fakeGatewayFinalText(initialMarker),
      ]);
      gateways.push(initialGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, initialGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save a turn for resume.");
      await active.waitForText(initialMarker, TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(stderrPath, "utf8")).not.toContain("AnsiBandOverflow");

      const sessionId = sessionIdFromHome(home);
      const resumeViewPath = join(
        home,
        ".fx",
        "sessions",
        sessionId,
        "resume-view.bin",
      );
      expect(existsSync(resumeViewPath)).toBe(true);
      const initialResumeView = readFileSync(resumeViewPath);

      const pickerGateway = startFakeGateway([]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} -r`,
        cwd: workspaceRoot,
        env: gatewayEnv(home, pickerGateway),
        stderrPath,
      });
      const picker = await active.waitForPane(
        (pane) =>
          pane.includes("Sessions 1") &&
          pane.includes("Save a turn for resume.") &&
          pane.includes("Enter Resume"),
        TIMEOUT,
      );
      expect(picker).toContain("Save a turn for resume.");
      await active.sendKeys("Enter");
      await active.waitForComposer(TIMEOUT);
      expect(await waitForScrollback(active, initialMarker)).toContain(initialMarker);
      expect(sessionIdFromHome(home)).toBe(sessionId);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      writeFileSync(resumeViewPath, initialResumeView);

      const invocations = [
        ["-c"],
        ["--continue"],
        ["--resume"],
        ["--resume-last"],
        [`--resume-${sessionId}`],
        ["resume", "--resume", "--last"],
      ];
      for (const [index, args] of invocations.entries()) {
        const restoredMarker =
          index === 0 ? initialMarker : `resume follow-up ${index - 1}`;
        const followUp = `resume follow-up ${index}`;
        const tapePath = join(root, `startup-resume-${index}.fxtape`);
        const tracePath = join(root, `startup-resume-${index}.trace.log`);
        const gateway = startFakeGateway([fakeGatewayFinalText(followUp)]);
        gateways.push(gateway);
        writeFileSync(stderrPath, "");
        active = await TmuxSession.create({
          cmd: `${FX_BIN} ${args.join(" ")}`,
          cwd: workspaceRoot,
          env: {
            ...gatewayEnv(home, gateway),
            FX_RECORD: tapePath,
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "session",
          },
          stderrPath,
          width: args[0] === `--resume-${sessionId}` ? 42 : 100,
          height: args[0] === `--resume-${sessionId}` ? 16 : 32,
        });
        await active.waitForComposer(TIMEOUT);
        const scrollback = await waitForScrollback(active, restoredMarker);
        expect(scrollback).toContain(restoredMarker);
        await active.sendText(`Continue session ${index}.`);
        await active.waitForText(followUp, TIMEOUT);
        expect(sessionIdFromHome(home)).toBe(sessionId);
        expect(active.isPaneAlive()).toBe(true);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd()).toBe(true);
        await active.kill();
        active = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        const resumeTrace = readFileSync(tracePath, "utf8");
        expect(resumeTrace).toMatch(
          /event=resume_view_cache (?:outcome=painted freshness=exact|outcome=skipped freshness=(?:exact|older))/,
        );
        const replay = await runFx(["replay", tapePath, "--frames"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(replay.code).toBe(0);
        expect(replay.stderr).toBe("");
        expect(replay.stdout).not.toMatch(/Run \/help for commands/i);
        const firstApplicationFrame = replay.stdout
          .split(/(?=--- frame \d+)/)
          .find((frame) =>
            /Recording:|Session:|Run \/help for commands|auto ·/.test(frame),
          );
        expect(firstApplicationFrame).toContain(restoredMarker);
        if (index === 0) {
          writeFileSync(resumeViewPath, initialResumeView);
        }
      }

      const markdownHome = join(root, "markdown-home");
      const markdownWorkspace = join(root, "markdown-workspace");
      const markdownStderrPath = join(root, "markdown-stderr.log");
      const markdownTapePath = join(root, "markdown-live.fxtape");
      const resumedMarkdownTapePath = join(root, "markdown-resumed.fxtape");
      mkdirSync(markdownHome);
      mkdirSync(markdownWorkspace);
      const markdown = [
        "## Resume Markdown Probe",
        "",
        "RESUME_MARKDOWN_TOP_MARKER with **BOLD_MARKER** and `INLINE_MARKER`.",
        "",
        "- [x] RESUME_MARKDOWN_TASK_MARKER",
        "",
        "| Row | Value |",
        "| --- | --- |",
        ...Array.from(
          { length: 14 },
          (_, index) => `| REPRO_TABLE_${String(index + 1).padStart(2, "0")} | ${index + 1} |`,
        ),
        "",
        "| Type | Symbol | Description |",
        "| --- | --- | --- |",
        ...SEMANTIC_TABLE_ROWS.map((row) =>
          `| ${row.type} | ${row.symbol} | ${row.description} |`
        ),
        "",
        "```zig",
        ...Array.from(
          { length: 18 },
          (_, index) =>
            `const ${index === 17 ? "CODE_FINAL_MARKER" : `CODE_LINE_${String(index + 1).padStart(2, "0")}`} = ${index + 1};`,
        ),
        "```",
        "",
        "```",
        "const inferredHook = await resumeHook(token, { cleanup: true } as CleanupSignal);",
        "```",
        "",
        "```",
        '{"json_ready": true}',
        "```",
        "",
        "```python",
        "def render_ready():",
        "    return True",
        "```",
      ].join("\n");
      const markdownGateway = startFakeGateway([fakeGatewayFinalText(markdown)]);
      gateways.push(markdownGateway);
      writeFileSync(markdownStderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(markdownWorkspace),
        env: { ...gatewayEnv(markdownHome, markdownGateway), FX_RECORD: markdownTapePath },
        stderrPath: markdownStderrPath,
        width: 72,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save Markdown for resume.");
      const liveMarkdown = await waitForScrollback(active, "render_ready");
      expectRenderedMarkdown(liveMarkdown, "tmux");
      expectInferredTypeScriptCodeBlock(liveMarkdown);
      expectExpandedCodeProfiles(liveMarkdown);
      expectAlignedSemanticTable(liveMarkdown, "tmux");
      expectInferredTypeScriptColors(await active.captureFullScrollbackEscapes());
      expectExpandedCodeColors(await active.captureFullScrollbackEscapes());
      await active.resizeWindow(42, 32);
      await active.sendKeys("C-o");
      await Bun.sleep(250);
      const narrowFullTranscript = await collectFullTranscriptPages(active);
      expectSemanticTableRows(narrowFullTranscript, "tmux");
      expectAlignedSemanticCards(narrowFullTranscript, "tmux");
      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(markdownStderrPath, "utf8")).not.toContain("AnsiBandOverflow");
      const liveReplay = await runFx(["replay", markdownTapePath, "--frames"], {
        cwd: realpathSync(markdownWorkspace),
        env: { HOME: markdownHome },
      });
      expect(liveReplay.code).toBe(0);
      expect(liveReplay.stderr).toBe("");
      expect(liveReplay.stdout).toContain("json_ready");
      expect(liveReplay.stdout).toContain("render_ready");
      expectSemanticTableRows(liveReplay.stdout, "replay");
      expectAlignedSemanticCards(liveReplay.stdout, "replay");

      const resumedMarkdownGateway = startFakeGateway([]);
      gateways.push(resumedMarkdownGateway);
      writeFileSync(markdownStderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: realpathSync(markdownWorkspace),
        env: { ...gatewayEnv(markdownHome, resumedMarkdownGateway), FX_RECORD: resumedMarkdownTapePath },
        stderrPath: markdownStderrPath,
        width: 42,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      const resumedMarkdown = await waitForScrollback(active, "render_ready");
      expect(resumedMarkdown).toContain("render_ready");
      expectInferredTypeScriptCodeBlock(resumedMarkdown);
      expectExpandedCodeProfiles(resumedMarkdown);
      expectInferredTypeScriptColors(await active.captureFullScrollbackEscapes());
      expectExpandedCodeColors(await active.captureFullScrollbackEscapes());
      await active.sendKeys("C-o");
      await Bun.sleep(250);
      const resumedFullTranscript = await collectFullTranscriptPages(active);
      expectRenderedMarkdown(resumedFullTranscript, "tmux");
      expectInferredTypeScriptCodeBlock(resumedFullTranscript);
      expectExpandedCodeProfiles(resumedFullTranscript);
      expectSemanticTableRows(resumedFullTranscript, "tmux");
      expectAlignedSemanticCards(resumedFullTranscript, "tmux");
      await active.sendKeys("Escape");
      await active.waitForComposer(TIMEOUT);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(markdownStderrPath, "utf8")).not.toContain("AnsiBandOverflow");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      const resumedReplay = await runFx(["replay", resumedMarkdownTapePath, "--frames"], {
        cwd: realpathSync(markdownWorkspace),
        env: { HOME: markdownHome },
      });
      expect(resumedReplay.code).toBe(0);
      expect(resumedReplay.stderr).toBe("");
      expect(resumedReplay.stdout).toContain("json_ready");
      expect(resumedReplay.stdout).toContain("render_ready");
      expectSemanticTableRows(resumedReplay.stdout, "replay");
      expectAlignedSemanticCards(resumedReplay.stdout, "replay");

      const toolHome = join(root, "tool-home");
      const toolWorkspace = join(root, "tool-workspace");
      const toolStderrPath = join(root, "tool-stderr.log");
      const toolWorkspaceMarker = "tool-workspace";
      mkdirSync(join(toolHome, ".fx"), { recursive: true });
      mkdirSync(toolWorkspace);
      writeFileSync(
        join(toolHome, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "legacy" }),
      );
      const toolWorkspaceRoot = realpathSync(toolWorkspace);
      const toolReply = "TOOL_RESUME_FINAL_REPLY";
      const toolGateway = startFakeGateway([
        fakeGatewayToolCall("resume_pwd", "terminal", { action: "exec", command: "pwd" }),
        fakeGatewayFinalText(toolReply),
      ]);
      gateways.push(toolGateway);
      writeFileSync(toolStderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: toolWorkspaceRoot,
        env: gatewayEnv(toolHome, toolGateway),
        stderrPath: toolStderrPath,
        width: 80,
        height: 24,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run pwd once for resume.");
      const liveToolScrollback = await waitForScrollback(active, toolReply);
      expect(liveToolScrollback).toContain("Ran pwd");
      expect(liveToolScrollback).toContain(toolWorkspaceMarker);
      expectNoRawToolReplay(liveToolScrollback);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(toolStderrPath, "utf8")).not.toContain("AnsiBandOverflow");

      const toolSessionId = sessionIdFromHome(toolHome);
      const toolInvocations = [
        ["--resume"],
        ["--resume-last"],
        [`--resume-${toolSessionId}`],
      ];
      for (const [index, args] of toolInvocations.entries()) {
        const followUp = `tool resume follow-up ${index}`;
        const gateway = startFakeGateway([fakeGatewayFinalText(followUp)]);
        gateways.push(gateway);
        writeFileSync(toolStderrPath, "");
        active = await TmuxSession.create({
          cmd: `${FX_BIN} ${args.join(" ")}`,
          cwd: toolWorkspaceRoot,
          env: gatewayEnv(toolHome, gateway),
          stderrPath: toolStderrPath,
          width: 80,
          height: 24,
        });
        await active.waitForComposer(TIMEOUT);
        const resumedToolScrollback = await waitForScrollback(active, toolReply);
        expect(resumedToolScrollback).toContain("Ran pwd");
        expect(resumedToolScrollback).toContain(toolWorkspaceMarker);
        expect(resumedToolScrollback).toContain(toolReply);
        expectNoRawToolReplay(resumedToolScrollback);
        if (index === 0) {
          await active.sendKeys("C-o");
          await active.sendKeys("Right");
          await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
          await active.waitForText(toolWorkspaceMarker, TIMEOUT);
          const full = await active.capturePane();
          expect(full).toContain("Ran pwd");
          expect(full).toContain(toolWorkspaceMarker);
          await active.sendKeys("C-o");
          await active.waitForComposer(TIMEOUT);
        }
        await active.sendText(`Continue the tool session ${index}.`);
        await active.waitForText(followUp, TIMEOUT);
        expect(active.isPaneAlive()).toBe(true);
        expect(readFileSync(toolStderrPath, "utf8")).not.toContain("AnsiBandOverflow");
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd()).toBe(true);
        await active.kill();
        active = null;
      }
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 5,
);

test.skipIf(!tmuxAvailable())(
  "upgrade ctrl-g reloads the background-installed binary and resumes",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-upgrade-ctrl-g-")));
    const home = join(root, "home");
    const freshHome = join(root, "fresh-home");
    const workspace = join(root, "workspace");
    const installDir = join(root, "install");
    const stderrPath = join(root, "stderr.log");
    const freshStderrPath = join(root, "fresh-stderr.log");
    const argvLogPath = join(root, "upgrade-argv.log");
    mkdirSync(home);
    mkdirSync(freshHome);
    mkdirSync(workspace);
    mkdirSync(installDir);
    const workspaceRoot = realpathSync(workspace);
    const installedFx = join(installDir, "fx");
    copyFileSync(FX_BIN, installedFx);
    chmodSync(installedFx, 0o755);

    let active: TmuxSession | null = null;
    let fresh: TmuxSession | null = null;
    const gateway = startFakeGateway([
      fakeGatewayFinalText("UPGRADE_CTRL_G_INITIAL_DONE"),
      fakeGatewayFinalText("UPGRADE_CTRL_G_FOLLOWUP_DONE"),
    ]);
    const release = startUpgradeServer(root, argvLogPath);

    try {
      writeFileSync(stderrPath, "");
      writeFileSync(freshStderrPath, "");
      active = await TmuxSession.create({
        cmd: shellQuote(installedFx),
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, gateway),
          FX_AUTO_UPGRADE: "1",
          FX_E2E_UPGRADE_BASE_URL: release.baseUrl,
        },
        stderrPath,
        width: 110,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save a turn before upgrade handoff.");
      await active.waitForText("UPGRADE_CTRL_G_INITIAL_DONE", TIMEOUT);
      await active.waitForComposer(TIMEOUT);
      const sessionId = sessionIdFromHome(home);

      await active.waitForText(
        "Update installed: ctrl+g to reload",
        UPGRADE_TIMEOUT,
      );
      expect(readFileSync(installedFx, "utf8")).toContain(argvLogPath);

      fresh = await TmuxSession.create({
        cmd: shellQuote(installedFx),
        cwd: workspaceRoot,
        env: gatewayEnv(freshHome, gateway),
        stderrPath: freshStderrPath,
        width: 110,
        height: 32,
      });
      await fresh.waitForComposer(TIMEOUT);
      expect(readFileSync(argvLogPath, "utf8").trim().split("\n")).toEqual([
        installedFx,
      ]);
      expect(await fresh.capturePane()).not.toContain("Update installed: ctrl+g to reload");
      await fresh.sendText("/quit");
      expect(await fresh.waitForSessionEnd()).toBe(true);
      await fresh.kill();
      fresh = null;

      const version = (await runFx(["--version"])).stdout.trim();
      await active.sendHexBytes(["07"]);

      const updatedNotice = `● 𝒇x has been updated to v${version}`;
      await active.waitForText(updatedNotice, TIMEOUT);
      const resumed = await waitForScrollback(active, "UPGRADE_CTRL_G_INITIAL_DONE");
      expect(resumed).toContain("UPGRADE_CTRL_G_INITIAL_DONE");
      expect(resumed).toContain(updatedNotice);
      expect(resumed).not.toContain("● Session resumed:");
      expect(resumed).not.toContain("● Session: resumed:");

      const argvLines = readFileSync(argvLogPath, "utf8").trim().split("\n");
      expect(argvLines).toEqual([
        installedFx,
        `${installedFx}\tresume\t${sessionId}\t--upgrade-relaunch`,
      ]);

      await active.sendText("Continue after upgrade handoff.");
      await active.waitForText("UPGRADE_CTRL_G_FOLLOWUP_DONE", TIMEOUT);
      const stderr = readFileSync(stderrPath, "utf8");
      expect(stderr).not.toContain("relaunch failed");
      expect(stderr).not.toContain("AnsiBandOverflow");
      expect(readFileSync(freshStderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (fresh) await fresh.kill();
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      release.stop();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  UPGRADE_TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "upgrade ctrl-g repairs an exact corrupt boundary and resumes",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-upgrade-corrupt-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const installDir = join(root, "install");
    const stderrPath = join(root, "stderr.log");
    const argvLogPath = join(root, "upgrade-argv.log");
    mkdirSync(home);
    mkdirSync(workspace);
    mkdirSync(installDir);
    const workspaceRoot = realpathSync(workspace);
    const installedFx = join(installDir, "fx");
    copyFileSync(FX_BIN, installedFx);
    chmodSync(installedFx, 0o755);

    let active: TmuxSession | null = null;
    const gateway = startFakeGateway([
      fakeGatewayFinalText("UPGRADE_CORRUPT_INITIAL_DONE"),
      fakeGatewayFinalText("UPGRADE_CORRUPT_FOLLOWUP_DONE"),
    ]);
    const release = startUpgradeServer(root, argvLogPath);

    try {
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: shellQuote(installedFx),
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, gateway),
          FX_AUTO_UPGRADE: "1",
          FX_E2E_UPGRADE_BASE_URL: release.baseUrl,
        },
        stderrPath,
        width: 110,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save this turn before the corrupt upgrade boundary.");
      await active.waitForText("UPGRADE_CORRUPT_INITIAL_DONE", TIMEOUT);
      await active.waitForComposer(TIMEOUT);
      await waitForCommittedSessionMarker(home, "UPGRADE_CORRUPT_INITIAL_DONE");
      const sessionId = sessionIdFromHome(home);
      await active.waitForText(
        "Update installed: ctrl+g to reload",
        UPGRADE_TIMEOUT,
      );

      const sessionDir = join(home, ".fx", "sessions", sessionId);
      const watermarkName = readdirSync(sessionDir).find(
        (name) => name.startsWith("commit.") && name.endsWith(".json"),
      )!;
      writeFileSync(join(sessionDir, watermarkName), "{}\n", { mode: 0o600 });
      const version = (await runFx(["--version"])).stdout.trim();
      await active.sendHexBytes(["07"]);

      await active.waitForText(`● 𝒇x has been updated to v${version}`, TIMEOUT);
      const resumed = await waitForScrollback(
        active,
        "UPGRADE_CORRUPT_INITIAL_DONE",
      );
      expect(resumed).toContain("UPGRADE_CORRUPT_INITIAL_DONE");
      expect(active.isPaneAlive()).toBe(true);
      const argvLines = readFileSync(argvLogPath, "utf8").trim().split("\n");
      expect(argvLines).toEqual([
        `${installedFx}\tresume\t${sessionId}\t--upgrade-relaunch`,
      ]);

      await active.sendText("Continue after repaired upgrade handoff.");
      await active.waitForText("UPGRADE_CORRUPT_FOLLOWUP_DONE", TIMEOUT);

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      release.stop();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  UPGRADE_TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "answered question cards survive flag and picker resume",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-resume-question-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const questionMarker = "RESUME_QUESTION_VERIFICATION_DEPTH";
    const answer = "Thorough";
    const completion = "RESUME_QUESTION_COMPLETED";
    const flagFollowUp = "RESUME_QUESTION_FLAG_FOLLOW_UP";
    const pickerFollowUp = "RESUME_QUESTION_PICKER_FOLLOW_UP";
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    const expectCompactQuestion = (scrollback: string) => {
      expect(scrollback).toContain(`\n  1) ${questionMarker}`);
      expect(scrollback).toContain(`     ${answer}`);
      expect(scrollback).not.toContain("● Asked");
      expect(scrollback).not.toContain(`\"question\":\"${questionMarker}\"`);
    };

    const expectQuestionDetail = async (session: TmuxSession) => {
      await session.sendKeys("C-o");
      await session.waitForText(`\"answer\":\"${answer}\"`, TIMEOUT);
      const full = await session.capturePane();
      expect(full).toContain(questionMarker);
      expect(full).toContain(`\"question\":\"${questionMarker}\"`);
      expect(full).toContain(`\"answer\":\"${answer}\"`);
      expect(full).not.toMatch(/^\s*(?:input|result)\s*$/m);
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
    };

    try {
      const initialGateway = startFakeGateway([
        fakeGatewayToolCall("resume_question", "ask_user_question", {
          questions: [
            {
              question: questionMarker,
              options: [
                { label: answer, description: "Run every verification step." },
                { label: "Fast", description: "Run only the focused checks." },
              ],
            },
          ],
        }),
        fakeGatewayFinalText(completion),
      ]);
      gateways.push(initialGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, initialGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Ask the prepared verification question.");
      await active.waitForText(questionMarker, TIMEOUT);
      await active.sendLiteralText("1");
      await active.sendKeys("Enter");
      const live = await waitForScrollback(active, completion);
      expectCompactQuestion(live);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const flagGateway = startFakeGateway([fakeGatewayFinalText(flagFollowUp)]);
      gateways.push(flagGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: workspaceRoot,
        env: gatewayEnv(home, flagGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      const flagResumed = await waitForScrollback(active, completion);
      expectCompactQuestion(flagResumed);
      await expectQuestionDetail(active);
      await active.sendText("Continue the resumed flag session.");
      await active.waitForText(flagFollowUp, TIMEOUT);
      expect(active.isPaneAlive()).toBe(true);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const pickerGateway = startFakeGateway([fakeGatewayFinalText(pickerFollowUp)]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, pickerGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendHexBytes(["1b", "5b", "31", "31", "34", "3b", "39", "75"]);
      await waitForSessionPicker(active);
      await active.sendKeys("Enter");
      const pickerResumed = await waitForScrollback(active, flagFollowUp);
      expectCompactQuestion(pickerResumed);
      await expectQuestionDetail(active);
      await active.sendText("Continue the resumed picker session.");
      await active.waitForText(pickerFollowUp, TIMEOUT);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 4,
);

test.skipIf(!tmuxAvailable())(
  "recorded file diffs survive resume and retain their Ctrl-O detail",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-resume-file-diff-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const initialTapePath = join(root, "initial.fxtape");
    const resumedTapePath = join(root, "resumed.fxtape");
    const firstLines = Array.from(
      { length: 120 },
      (_, index) => `RESUMED_FIRST_FILE_LINE_${String(index + 1).padStart(3, "0")}`,
    );
    const secondLines = Array.from(
      { length: 60 },
      (_, index) => `RESUMED_SECOND_FILE_LINE_${String(index + 1).padStart(3, "0")}`,
    );
    const firstCompletion = "RESUMED_FIRST_FILE_COMPLETE";
    const secondCompletion = "RESUMED_SECOND_FILE_COMPLETE";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(stderrPath, "");

    const initialGateway = startFakeGateway([
      fakeGatewayToolCall("resume_file_diff", "write_file", {
        path: "first-large.md",
        content: `${firstLines.join("\n")}\n`,
      }),
      fakeGatewayFinalText(firstCompletion),
      fakeGatewayToolCall("resume_second_file_diff", "write_file", {
        path: "second-large.md",
        content: `${secondLines.join("\n")}\n`,
      }),
      fakeGatewayFinalText(secondCompletion),
    ]);
    const resumedGateway = startFakeGateway([]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, initialGateway), FX_RECORD: initialTapePath },
        stderrPath,
        width: 120,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Create the first prepared resume file fixture.");
      await active.waitForText("Apply this change?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      const firstLive = await waitForScrollback(active, firstCompletion);
      expect(firstLive).toContain("Wrote first-large.md");
      expect(firstLive).toContain("⋯ +");
      expect(readFileSync(join(workspace, "first-large.md"), "utf8")).toBe(
        `${firstLines.join("\n")}\n`,
      );

      await active.sendText("Create the second prepared resume file fixture.");
      await active.waitForText("Apply this change?", TIMEOUT);
      await active.sendKeys("1");
      await active.sendKeys("Enter");
      const live = await waitForScrollback(active, secondCompletion);
      expect(live).toContain("Wrote first-large.md");
      expect(live).toContain("Wrote second-large.md");
      expect(live).toContain("⋯ +");
      expect(readFileSync(join(workspace, "second-large.md"), "utf8")).toBe(
        `${secondLines.join("\n")}\n`,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const sessionId = sessionIdFromHome(home);
      const eventsJsonl = readFileSync(
        join(home, ".fx", "sessions", sessionId, "events.jsonl"),
        "utf8",
      );
      expect(eventsJsonl).toContain("committed_file_presentation");
      expect(eventsJsonl).not.toContain("sk-abcdefghijklmnop");
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-${sessionId}`,
        cwd: realpathSync(workspace),
        env: { ...gatewayEnv(home, resumedGateway), FX_RECORD: resumedTapePath },
        stderrPath,
        width: 120,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      const resumed = await waitForScrollback(active, secondCompletion);
      expect(resumed).toContain("Wrote first-large.md");
      expect(resumed).toContain("Wrote second-large.md");
      expect(resumed).toContain("⋯ +");

      await active.sendKeys("C-o");
      await active.waitForText("┃ Review · ←/→ switch · ctrl o close", TIMEOUT);
      const review = await active.capturePane();
      expect(review).toContain("RESUMED_SECOND_FILE_LINE_001");
      expect(review).toContain("RESUMED_SECOND_FILE_LINE_003");
      expect(review).not.toContain("RESUMED_SECOND_FILE_LINE_004");
      expect(review).not.toContain("RESUMED_SECOND_FILE_LINE_060");
      expect(review).toContain("57 more lines · → to expand");
      expect(review).toMatch(/^  │  57 more lines · → to expand/m);
      expect(review).not.toMatch(/^│  57 more lines · → to expand/m);
      expect(review).not.toMatch(/^\s*│?\s*60 lines\s*$/m);
      await active.sendKeys("Right");
      await active.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      await active.sendHexBytes(
        Array.from({ length: 10 }, () => ["1b", "5b", "36", "7e"]).flat(),
      );
      await active.waitForText("RESUMED_SECOND_FILE_LINE_060", TIMEOUT);
      const secondFull = await active.capturePane();
      expect(secondFull).toContain("RESUMED_SECOND_FILE_LINE_060");
      expect(secondFull).not.toContain('"content":"RESUMED_SECOND_FILE_LINE');
      await active.sendHexBytes(
        Array.from({ length: 2 }, () => ["1b", "5b", "35", "7e"]).flat(),
      );
      await active.waitForText("RESUMED_FIRST_FILE_LINE_120", TIMEOUT);
      const firstFull = await active.capturePane();
      expect(firstFull).toContain("RESUMED_FIRST_FILE_LINE_120");
      expect(firstFull).not.toContain('"content":"RESUMED_FIRST_FILE_LINE');

      await active.sendKeys("C-o");
      await active.waitForText("⋯ +", TIMEOUT);

      await active.sendText("/undo");
      await active.waitForText("Nothing to undo.", TIMEOUT);
      expect(readFileSync(join(workspace, "first-large.md"), "utf8")).toBe(
        `${firstLines.join("\n")}\n`,
      );
      expect(readFileSync(join(workspace, "second-large.md"), "utf8")).toBe(
        `${secondLines.join("\n")}\n`,
      );
      const replay = await runFx(["replay", resumedTapePath, "--frames"], {
        cwd: realpathSync(workspace),
        env: { HOME: home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain("RESUMED_FIRST_FILE_LINE_120");
      expect(replay.stdout).toContain("RESUMED_SECOND_FILE_LINE_060");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (active) {
        try {
          await active.sendText("/quit");
        } catch {}
        await active.kill();
      }
      initialGateway.stop();
      resumedGateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  90_000,
);

test.skipIf(!tmuxAvailable())(
  "command output folding survives flag and picker resume",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-resume-command-output-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    mkdirSync(join(home, ".fx"), { recursive: true });
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {}, maxxing_mode: "legacy" }),
    );
    const lineCount = 40;
    const commandLine = "x".repeat(40);
    const stderrTail1 = "RESUME_COMMAND_STDERR_TAIL_1";
    const stdoutTail1 = "RESUME_COMMAND_STDOUT_TAIL_1";
    const stderrTail2 = "RESUME_COMMAND_STDERR_TAIL_2";
    const stdoutTail2 = "RESUME_COMMAND_STDOUT_TAIL_2";
    const scriptPath = join(workspace, "resume-command-output.sh");
    const fixtureCommand = "./resume-command-output.sh";
    writeFileSync(
      scriptPath,
      `#!/bin/sh
i=0
while [ "$i" -lt ${lineCount} ]; do
  printf 'RESUME_COMMAND_LINE_%03d: ${commandLine}\\n' "$i"
  i=$((i + 1))
done
printf '\\n'
printf 'RESUME_COMMAND_TAIL\\n'
printf '${stderrTail1}\\n' >&2
sleep 0.5
printf '${stdoutTail1}\\n'
sleep 0.5
printf '${stderrTail2}\\n' >&2
sleep 0.5
printf '${stdoutTail2}\\n'
`,
    );
    chmodSync(scriptPath, 0o755);
    const orderedTailMarkers = [stderrTail1, stdoutTail1, stderrTail2, stdoutTail2];
    for (const marker of orderedTailMarkers) expect(fixtureCommand).not.toContain(marker);
    const firstMarker = "RESUME_COMMAND_LINE_000";
    const completion = "RESUME_COMMAND_OUTPUT_COMPLETE";
    const compactHint = "lines more (ctrl o to view)";
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    function expectCompactCommandOutput(pane: string): void {
      const lines = pane.split("\n");
      const hintIndex = lines.findIndex((line) => line.includes(compactHint));
      expect(hintIndex).toBeGreaterThanOrEqual(5);
      const payloadRows = lines.slice(hintIndex - 5, hintIndex);
      expect(payloadRows).toHaveLength(5);
      for (const row of payloadRows) expect(row.trimStart().startsWith("│ ")).toBe(true);
      expect(pane).toContain(firstMarker);
      expect(pane).not.toContain("RESUME_COMMAND_TAIL");
    }

    async function expectRestoredViewerOutput(session: TmuxSession): Promise<void> {
      await session.sendKeys("C-o");
      await session.waitForText("┃ Review · ←/→ switch · ctrl o close", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText("┃ Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      const tail = await session.capturePane();
      expect(tail).toContain(stdoutTail2);
      expect(tail).not.toContain(firstMarker);

      const pages = [tail];
      for (let page = 0; page < 8 && !pages.at(-1)!.includes(firstMarker); page += 1) {
        await session.sendHexBytes(["1b", "5b", "35", "7e"]);
        const next = await waitForChangedPane(session, pages.at(-1)!);
        if (next === null) break;
        pages.push(next);
      }
      const head = pages.at(-1)!;
      expect(head).toContain(`│ ${firstMarker}`);
      expect(countOccurrences(head, firstMarker)).toBe(1);
      const output = [...pages].reverse().join("\n").split("\n").filter((line) =>
        line.trimStart().startsWith("│ ") && !line.includes("command:")
      ).join("\n");
      for (const marker of orderedTailMarkers) {
        expect(output).toContain(marker);
      }
      expect(output.indexOf(stderrTail1)).toBeLessThan(
        output.indexOf(stdoutTail1),
      );
      expect(output.indexOf(stdoutTail1)).toBeLessThan(
        output.indexOf(stderrTail2),
      );
      expect(output.indexOf(stderrTail2)).toBeLessThan(
        output.indexOf(stdoutTail2),
      );
      expect(tail).not.toContain(firstMarker);
      expect(tail).not.toContain("<stdout>");
      expect(tail).not.toContain("</stdout>");
      expect(tail).not.toContain("<stderr>");
      expect(tail).not.toContain("</stderr>");
      await session.sendKeys("C-o");
      await session.waitForComposer(TIMEOUT);
    }

    try {
      const initialGateway = startFakeGateway([
        fakeGatewayToolCall("resume_long_command", "terminal", { action: "exec", command: fixtureCommand }),
        fakeGatewayFinalText(completion),
      ]);
      gateways.push(initialGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: { ...gatewayEnv(home, initialGateway), FX_PERMISSION_MODE: "ask" },
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the long command for resume.");
      await active.waitForText("Would you like to run the following command?", TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText(completion, TIMEOUT);
      await active.waitForPane((pane) => pane.includes(compactHint), TIMEOUT);
      const live = await active.capturePane();
      expectCompactCommandOutput(live);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const flagGateway = startFakeGateway([]);
      gateways.push(flagGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: workspaceRoot,
        env: gatewayEnv(home, flagGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.waitForPane((pane) => pane.includes(compactHint), TIMEOUT);
      const flagResumed = await active.capturePane();
      expectCompactCommandOutput(flagResumed);
      expectNoRawToolReplay(flagResumed);
      await expectRestoredViewerOutput(active);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const pickerGateway = startFakeGateway([]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, pickerGateway),
        stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/resume");
      await waitForSessionPicker(active);
      await active.sendKeys("Enter");
      await active.waitForPane((pane) => pane.includes(compactHint), TIMEOUT);
      const pickerResumed = await active.capturePane();
      expectCompactCommandOutput(pickerResumed);
      expectNoRawToolReplay(pickerResumed);
      await expectRestoredViewerOutput(active);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 4,
);

test.skipIf(!tmuxAvailable())(
  "interactive /resume opens a searchable scoped catalog and resumes the selection",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-picker-workspace-")));
    const home = join(root, "home");
    const workspaceA = join(root, "workspace-a");
    const workspaceB = join(root, "workspace-b");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspaceA);
    mkdirSync(workspaceB);
    const workspaceARoot = realpathSync(workspaceA);
    const workspaceBRoot = realpathSync(workspaceB);
    const workspaceAMarker = "SESSION_PICKER_WORKSPACE_A_ONLY";
    const workspaceBMarker = "SESSION_PICKER_WORKSPACE_B_FOREIGN";
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      const workspaceAGateway = startFakeGateway([fakeGatewayFinalText(workspaceAMarker)]);
      gateways.push(workspaceAGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceARoot,
        env: gatewayEnv(home, workspaceAGateway),
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save the workspace A transcript.");
      await active.waitForText(workspaceAMarker, TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const workspaceBGateway = startFakeGateway([fakeGatewayFinalText(workspaceBMarker)]);
      gateways.push(workspaceBGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceBRoot,
        env: gatewayEnv(home, workspaceBGateway),
        stderrPath,
        width: 100,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save the workspace B transcript.");
      await active.waitForText(workspaceBMarker, TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const pickerGateway = startFakeGateway([]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceARoot,
        env: gatewayEnv(home, pickerGateway),
        stderrPath,
        width: 160,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/resume");
      await waitForSessionPicker(active);
      const currentPicker = stripAnsi(await active.capturePane());
      expect(currentPicker).toContain("Sessions 1");
      expect(currentPicker).toContain("[Current workspace]");
      expect(currentPicker).not.toContain("𝒇x");
      expect(currentPicker).toContain("Save the workspace A transcript.");
      expect(currentPicker).not.toContain("Save the workspace B transcript.");

      await active.sendKeys("Tab");
      await active.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return plain.includes("Sessions 2") &&
          plain.includes("[All workspaces]") &&
          plain.includes("Save the workspace B transcript.");
      }, TIMEOUT);
      const allPicker = stripAnsi(await active.capturePane());
      expect(allPicker).toContain("Save the workspace A transcript.");
      expect(allPicker).toContain("Save the workspace B transcript.");
      expect(allPicker).toContain("Tab Scope");

      await active.sendLiteralText("workspace B");
      await active.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return plain.includes("Sessions 1") &&
          plain.includes("Save the workspace B transcript.") &&
          !plain.includes("Save the workspace A transcript.");
      }, TIMEOUT);
      const filteredPicker = stripAnsi(await active.capturePane());
      expect(filteredPicker).toContain("workspace B");
      expect(filteredPicker).toContain("workspace-b");
      expect(filteredPicker).not.toContain("Preview:");
      const sessionIds = readdirSync(join(home, ".fx", "sessions"), {
        withFileTypes: true,
      })
        .filter((entry) => entry.name !== "latest" && entry.isDirectory())
        .map((entry) => entry.name);
      for (const sessionId of sessionIds) {
        expect(filteredPicker).not.toContain(sessionId);
      }
      await active.sendKeys("Enter");
      const resumed = await waitForScrollback(active, workspaceBMarker);
      expect(resumed).toContain("● Session resumed: Save the workspace B transcript.");
      expect(resumed).toContain(workspaceBMarker);
      expect(resumed).not.toContain(workspaceAMarker);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "interactive /resume keeps shared-prefix titles distinguishable at narrow widths",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-picker-narrow-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const titles = ["alpha", "beta", "gamma"].map(
      (suffix) =>
        `Shared production composer regression investigation session ${suffix}`,
    );
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      const sessionGateway = startFakeGateway(
        titles.map((_, index) => fakeGatewayFinalText(`SESSION_TITLE_${index}`)),
      );
      gateways.push(sessionGateway);
      for (let index = 0; index < titles.length; index += 1) {
        writeFileSync(stderrPath, "");
        active = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: workspaceRoot,
          env: gatewayEnv(home, sessionGateway),
          stderrPath,
          width: 80,
          height: 24,
        });
        await active.waitForComposer(TIMEOUT);
        await active.sendText(titles[index]!);
        await active.waitForText(`SESSION_TITLE_${index}`, TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd()).toBe(true);
        await active.kill();
        active = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      }

      const pickerGateway = startFakeGateway([]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, pickerGateway),
        stderrPath,
        width: 40,
        height: 24,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/resume");
      const pane = stripAnsi(await waitForSessionPicker(active));
      expect(pane).toContain("Sessions 3");
      for (const suffix of ["alpha", "beta", "gamma"]) {
        expect(pane).toContain(suffix);
      }
      const rows = pane
        .split("\n")
        .filter((line) => /(?:alpha|beta|gamma)\b.*\bturns?\b/.test(line))
        .map((line) => line.trim());
      expect(new Set(rows).size).toBe(titles.length);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (active) await active.kill();
      for (const current of gateways) current.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 4,
);

test.skipIf(!tmuxAvailable())(
  "interactive /resume highlight reaches bottom before the list scrolls",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-picker-row-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    // 12 saved sessions exercise a first page that is taller than the viewport.
    const savedMarkers = Array.from(
      { length: 12 },
      (_, index) => `SESSION_PICKER_ROW_${index}`,
    );
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      for (const marker of savedMarkers) {
        const responseMarker = `${marker}_SAVED`;
        const gateway = startFakeGateway([fakeGatewayFinalText(responseMarker)]);
        gateways.push(gateway);
        writeFileSync(stderrPath, "");
        active = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: workspaceRoot,
          env: {
            ...gatewayEnv(home, gateway),
            FX_THEME: "dark",
            NO_COLOR: undefined,
          },
          stderrPath,
          width: 100,
          height: 30,
        });
        await active.waitForComposer(TIMEOUT);
        await active.sendText(`Save ${marker}.`);
        await active.waitForText(responseMarker, TIMEOUT);
        await waitForPersistedSessionMarker(home, responseMarker);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd()).toBe(true);
        await active.kill();
        active = null;
      }

      const pickerGateway = startFakeGateway([]);
      gateways.push(pickerGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, pickerGateway),
          FX_THEME: "dark",
          NO_COLOR: undefined,
        },
        stderrPath,
        width: 100,
        height: 15,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendHexBytes(["1b", "5b", "31", "31", "34", "3b", "39", "75"]);
      await waitForSessionPicker(active);

      let sessionEntries = visibleSessionPickerEntries(await active.capturePaneEscapes());
      expect(sessionEntries.length).toBeGreaterThanOrEqual(7);
      expect(sessionEntries.findIndex((entry) => entry.selected)).toBe(0);
      const firstVisibleRow = sessionEntries[0]!.row;
      const firstVisibleTitle = sessionEntries[0]!.title;
      const visibleCount = sessionEntries.length;

      for (let index = 0; index < visibleCount - 1; index += 1) {
        await active.sendKeys("Down");
        sessionEntries = visibleSessionPickerEntries(await active.capturePaneEscapes());
        expect(sessionEntries).toHaveLength(visibleCount);
        expect(sessionEntries[0]!.row).toBe(firstVisibleRow);
        expect(sessionEntries.findIndex((entry) => entry.selected)).toBe(index + 1);
        expect(sessionEntries.find((entry) => entry.selected)!.row).toBe(firstVisibleRow + index + 1);
      }

      await active.sendKeys("Down");
      const scrolledEntries = visibleSessionPickerEntries(await active.capturePaneEscapes());
      expect(scrolledEntries).toHaveLength(visibleCount);
      expect(scrolledEntries[0]!.row).toBe(firstVisibleRow);
      expect(scrolledEntries[0]!.title).not.toBe(firstVisibleTitle);
      expect(scrolledEntries.findIndex((entry) => entry.selected)).toBe(visibleCount - 1);
      expect(scrolledEntries.find((entry) => entry.selected)!.row).toBe(firstVisibleRow + visibleCount - 1);

      await active.sendKeys("Up");

      const reversedEntries = visibleSessionPickerEntries(await active.capturePaneEscapes());
      expect(reversedEntries).toHaveLength(visibleCount);
      expect(reversedEntries[0]!.row).toBe(firstVisibleRow);
      expect(reversedEntries.findIndex((entry) => entry.selected)).toBe(visibleCount - 2);
      expect(reversedEntries.find((entry) => entry.selected)!.row).toBe(firstVisibleRow + visibleCount - 2);

      const atReversedSelection = (await active.capturePane()).split("\n");
      const headerRow = atReversedSelection.findIndex((line) => line.includes("Sessions 10"));
      const loadMoreRow = atReversedSelection.findIndex((line) => line.includes("↓ Load more"));
      const hintRow = atReversedSelection.findIndex((line) => line.includes("Tab Scope"));
      expect(headerRow).toBeGreaterThanOrEqual(0);
      expect(loadMoreRow).toBeGreaterThan(headerRow);
      expect(hintRow).toBeGreaterThan(loadMoreRow);
      const firstEntryRow = visibleSessionPickerEntries(await active.capturePaneEscapes())[0]!.row;

      await active.sendKeys("Down");
      await active.sendKeys("Down");
      await active.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return /Sessions 1[12]\b/.test(plain) && !plain.includes("Load more");
      }, TIMEOUT);
      const afterFurtherScroll = (await active.capturePane()).split("\n");
      expect(afterFurtherScroll.findIndex((line) => /Sessions 1[12]\b/.test(line))).toBe(headerRow);
      expect(afterFurtherScroll.findIndex((line) => line.includes("↓ Load more"))).toBe(-1);
      expect(afterFurtherScroll.findIndex((line) => line.includes("Tab Scope"))).toBe(hintRow);
      expect(visibleSessionPickerEntries(await active.capturePaneEscapes())[0]!.row).toBe(firstEntryRow);

      expect(active.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendKeys("Escape");
      await waitForSessionPickerClosed(active);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "interactive /resume loads more sessions and dismisses cleanly",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-picker-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const savedMarkers = Array.from(
      { length: 11 },
      (_, index) => `SESSION_PICKER_HISTORY_${index}`,
    );
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      for (const marker of savedMarkers) {
        const responseMarker = `${marker}_SAVED`;
        const gateway = startFakeGateway([fakeGatewayFinalText(responseMarker)]);
        gateways.push(gateway);
        writeFileSync(stderrPath, "");
        active = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: workspaceRoot,
          env: gatewayEnv(home, gateway),
          stderrPath,
          width: 100,
          height: 30,
        });
        await active.waitForComposer(TIMEOUT);
        await active.sendText(`Save ${marker}.`);
        await active.waitForText(responseMarker, TIMEOUT);
        await waitForPersistedSessionMarker(home, responseMarker);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd()).toBe(true);
        await active.kill();
        active = null;
      }

      const gateway = startFakeGateway([]);
      gateways.push(gateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, gateway),
        stderrPath,
        width: 100,
        height: 15,
      });
      await active.waitForComposer(TIMEOUT);

      await active.sendText("/resume");
      await waitForSessionPicker(active);
      await active.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return plain.includes("Sessions 10") && plain.includes("Load more");
      }, TIMEOUT);
      for (let index = 0; index < 10; index += 1) {
        await active.sendKeys("Down");
      }
      await active.waitForPane((pane) => {
        const plain = stripAnsi(pane);
        return plain.includes("Sessions 11") &&
          plain.includes(`Save ${savedMarkers[0]}.`) &&
          !plain.includes("Load more");
      }, TIMEOUT);
      await active.sendLiteralText(savedMarkers[0]!);
      await active.waitForPane(
        (pane) => {
          const plain = stripAnsi(pane);
          return plain.includes("Sessions 1") &&
            plain.includes(`Save ${savedMarkers[0]!}.`);
        },
        TIMEOUT,
      );
      await active.sendKeys("Enter");
      const resumed = await waitForSessionPickerClosed(active);
      expect(resumed).toContain(`● Session resumed: Save ${savedMarkers[0]!}.`);
      expect(resumed).toContain(savedMarkers[0]!);

      await active.sendText("/resume");
      await waitForSessionPicker(active);
      await active.sendKeys("Escape");
      const afterEscape = await waitForSessionPickerClosed(active);
      expect(afterEscape).toContain(`● Session resumed: Save ${savedMarkers[0]!}.`);
      expect(afterEscape).toContain(savedMarkers[0]!);
      expect(afterEscape).not.toContain(`● Session resumed: Save ${savedMarkers[10]!}.`);
      expect(afterEscape).not.toContain(savedMarkers[10]!);

      await active.sendText("/resume");
      await waitForSessionPicker(active);
      await active.sendLiteralText(savedMarkers[10]!);
      await active.waitForPane(
        (pane) => {
          const plain = stripAnsi(pane);
          return plain.includes("Sessions 1") &&
            plain.includes(`Save ${savedMarkers[10]!}.`);
        },
        TIMEOUT,
      );
      await active.sendKeys("Enter");
      const secondResume = await waitForSessionPickerClosed(active);
      expect(secondResume).toContain(`● Session resumed: Save ${savedMarkers[10]!}.`);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "new and resumed sessions preserve native terminal scrollback while fx is active",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-direct-resume-scroll-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const initialTapePath = join(root, "new-session-scroll.fxtape");
    const tapePath = join(root, "direct-resume-scroll.fxtape");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const earlyMarker = "SESSION_PICKER_SCROLLBACK_EARLY";
    const lateMarker = "SESSION_PICKER_SCROLLBACK_LATE";
    const lines = Array.from(
      { length: 80 },
      (_, index) => `SESSION_PICKER_SCROLLBACK_LINE_${String(index).padStart(3, "0")} has enough text to wrap in the terminal viewport.`,
    );
    lines.unshift(earlyMarker);
    lines.push(lateMarker);
    const transcript = lines.join("\n");
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      const initialGateway = startFakeGateway([fakeGatewayFinalText(transcript)]);
      gateways.push(initialGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, initialGateway),
          FX_RECORD: initialTapePath,
        },
        stderrPath,
        width: 80,
        height: 24,
      });
      await active.waitForComposer(TIMEOUT);
      const initialTape = readFileSync(initialTapePath);
      expect(initialTape.includes(Buffer.from("\x1b[?1002h"))).toBe(false);
      expect(initialTape.includes(Buffer.from("\x1b[?1006h"))).toBe(false);
      expect(initialTape.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      await active.sendText("Save a long transcript for resume.");
      await waitForScrollback(active, lateMarker);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const sessionId = sessionIdFromHome(home);
      const resumedGateway = startFakeGateway([]);
      gateways.push(resumedGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: `${FX_BIN} resume ${sessionId}`,
        cwd: workspaceRoot,
        env: {
          ...gatewayEnv(home, resumedGateway),
          FX_RECORD: tapePath,
        },
        stderrPath,
        width: 80,
        height: 24,
      });
      await active.waitForComposer(TIMEOUT);

      const resumed = await waitForScrollback(active, earlyMarker);
      expect(resumed).toContain(earlyMarker);
      const tape = readFileSync(tapePath);
      expect(tape.includes(Buffer.from("\x1b[?1002h"))).toBe(false);
      expect(tape.includes(Buffer.from("\x1b[?1006h"))).toBe(false);
      expect(tape.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "interactive /resume refuses a live stream and preserves Escape cancellation",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-session-picker-stream-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    const workspaceRoot = realpathSync(workspace);
    const gateways: Array<ReturnType<typeof startFakeGateway>> = [];
    let active: TmuxSession | null = null;

    try {
      const savedGateway = startFakeGateway([fakeGatewayFinalText("saved session")]);
      gateways.push(savedGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, savedGateway),
        stderrPath,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Save a resumable turn.");
      await active.waitForText("saved session", TIMEOUT);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;

      const hold: HoldState = { started: false, cancelled: false };
      const heldGateway = startFakeGateway([() => heldGatewayResponse(hold)]);
      gateways.push(heldGateway);
      writeFileSync(stderrPath, "");
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspaceRoot,
        env: gatewayEnv(home, heldGateway),
        stderrPath,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Keep this response active.");
      await waitForCondition(() => hold.started, "held gateway response");
      await active.waitForText("Thinking", TIMEOUT);

      await active.sendText("/resume");
      await active.waitForText("resume is unavailable until the response finishes", TIMEOUT);
      const duringStream = await active.capturePane();
      expect(duringStream).not.toContain("updated");

      await active.sendKeys("Escape");
      await waitForCondition(() => hold.cancelled, "Escape to cancel the held response");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
    } finally {
      if (active) await active.kill();
      for (const gateway of gateways) gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT * 2,
);
test.skipIf(!tmuxAvailable())(
  "cancelled command presentation survives a distinct-process resume",
  async () => {
    const timeout = 60_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cancelled-command-resume-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const initialStderrPath = join(root, "initial-stderr.log");
    const resumedStderrPath = join(root, "resumed-stderr.log");
    const tracePath = join(root, "trace.log");
    const readyPath = join(workspace, ".interrupt-ready");
    const scriptPath = join(workspace, "resume-cancel.sh");
    const assistantMarker = "PARTIAL_ASSISTANT_BEFORE_INTERRUPT";
    const outputMarker = "INTERRUPT_START";
    const bufferedTailMarker = "INTERRUPT_BUFFERED_TAIL";
    const artifactTailMarker = "INTERRUPT_TERM_TAIL";
    const followUpMarker = "INTERRUPT_FOLLOW_UP_DONE";
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(initialStderrPath, "");
    writeFileSync(resumedStderrPath, "");
    writeFileSync(
      scriptPath,
      `#!/bin/sh
trap 'printf "${artifactTailMarker}\\n"; exit 0' TERM
printf '${outputMarker}\\n'
printf '${bufferedTailMarker}'
: > .interrupt-ready
while :; do sleep 1; done
`,
    );
    chmodSync(scriptPath, 0o755);

    const initialGateway = startFakeGateway([
      fakeGatewaySerializedToolCall(
        "resume-cancelled-command",
        "terminal",
        JSON.stringify({ action: "exec", command: "./resume-cancel.sh" }),
        assistantMarker,
      ),
      fakeGatewayFinalText(followUpMarker),
    ]);
    const resumedGateway = startFakeGateway([]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, initialGateway),
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "session,agent,tool,worker,interrupt,command_output,transcript",
        },
        stderrPath: initialStderrPath,
        width: 120,
        height: 40,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared interrupt command.");
      await waitForScrollback(active, outputMarker, timeout);
      await waitForCondition(
        () => existsSync(readyPath),
        "the interrupt command readiness file",
        timeout,
      );
      await active.sendKeys("Escape");
      await waitForScrollback(active, "Cancelled", timeout);
      await waitForCondition(
        () => existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=interrupt_persisted"),
        "the interrupted command history event",
        timeout,
      );
      const liveCancelled = stripAnsi(await active.captureFullScrollback());
      expect(liveCancelled).toContain(outputMarker);
      expect(liveCancelled).not.toContain(bufferedTailMarker);
      expect(liveCancelled).not.toContain(artifactTailMarker);

      await active.sendText("Reply with the prepared follow-up marker.");
      await waitForScrollback(active, followUpMarker, timeout);
      expect(initialGateway.requests).toHaveLength(2);
      const followUpBody = initialGateway.requests[1]!.body;
      expect(followUpBody).toContain("<turn_aborted>");
      expect(followUpBody).not.toContain(outputMarker);
      expect(followUpBody).not.toContain(bufferedTailMarker);
      expect(followUpBody).not.toContain(artifactTailMarker);
      expect(followUpBody).not.toContain("cancelled_command");
      expect(followUpBody).not.toContain("output_replay");
      expect(followUpBody).not.toContain("command_artifact_handle");
      expect(followUpBody).not.toContain(".command_artifacts");

      const sessionId = sessionIdFromHome(home);
      const commandDir = join(home, ".fx", "sessions", sessionId, "logs", "commands");
      const artifactName = readdirSync(commandDir).find((name) =>
        name.endsWith(".log") &&
        !name.endsWith(".stdout.log") &&
        !name.endsWith(".stderr.log")
      );
      expect(artifactName).toBeDefined();
      const artifact = readFileSync(join(commandDir, artifactName!), "utf8");
      expect(artifact).toContain(outputMarker);
      expect(artifact).toContain(bufferedTailMarker);
      expect(artifact).toContain(artifactTailMarker);
      expect(artifact.indexOf(artifactTailMarker)).toBeGreaterThan(artifact.indexOf(outputMarker));
      const artifactDigest = createHash("sha256")
        .update(artifact)
        .digest("hex")
        .slice(0, 16);
      expect(artifactName).toEndWith(`-${artifactDigest}.log`);
      expect(followUpBody).not.toContain(artifactName!);

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(initialStderrPath, "utf8")).toBe("");

      active = await TmuxSession.create({
        cmd: `${FX_BIN} resume last`,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, resumedGateway),
        stderrPath: resumedStderrPath,
        width: 120,
        height: 40,
      });
      await active.waitForComposer(TIMEOUT);
      const resumed = stripAnsi(await waitForScrollback(active, followUpMarker, timeout));
      const assistantIndex = resumed.indexOf(assistantMarker);
      const cancelledIndex = resumed.indexOf("Cancelled");
      const outputIndex = resumed.indexOf(outputMarker);
      const cancellationNoticeIndex = resumed.indexOf("● System: cancelled");
      expect(assistantIndex).toBeGreaterThanOrEqual(0);
      expect(cancelledIndex).toBeGreaterThan(assistantIndex);
      expect(outputIndex).toBeGreaterThan(cancelledIndex);
      expect(cancellationNoticeIndex).toBeGreaterThan(outputIndex);
      expect(countOccurrences(resumed, "● System: cancelled")).toBe(1);
      expect(resumed).not.toContain("Interrupted by user after completing");
      expect(resumed).not.toContain("<turn_aborted>");
      expect(resumed).not.toContain(bufferedTailMarker);
      expect(resumed).not.toContain(artifactTailMarker);

      await active.sendKeys("C-o");
      await active.waitForText(artifactTailMarker, timeout);
      const detail = stripAnsi(await active.capturePane()).replaceAll("\n", "");
      expect(detail).toContain(outputMarker);
      expect(detail).toContain(bufferedTailMarker);
      expect(detail).toContain(artifactTailMarker);
      expect(resumedGateway.requests).toHaveLength(0);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (active) {
        if (!passed) {
          try {
            writeFileSync(join(root, "failure-scrollback.txt"), await active.captureFullScrollback());
          } catch {}
        } else {
          try {
            await active.sendKeys("C-o");
            await active.sendText("/quit");
          } catch {}
        }
        await active.kill();
      }
      initialGateway.stop();
      resumedGateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained cancelled command resume artifacts at ${root}`);
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "zero-output cancelled command restores its row without an output block",
  async () => {
    const timeout = 60_000;
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-zero-output-cancel-resume-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const initialStderrPath = join(root, "initial-stderr.log");
    const resumedStderrPath = join(root, "resumed-stderr.log");
    const tracePath = join(root, "trace.log");
    const readyPath = join(workspace, ".zero-ready");
    const scriptPath = join(workspace, "z.sh");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {}, maxxing_mode: "legacy" }),
    );
    writeFileSync(initialStderrPath, "");
    writeFileSync(resumedStderrPath, "");
    writeFileSync(
      scriptPath,
      "#!/bin/sh\ntrap 'exit 0' TERM\n: > .zero-ready\nwhile :; do sleep 1; done\n",
    );
    chmodSync(scriptPath, 0o755);

    const initialGateway = startFakeGateway([
      fakeGatewayToolCall("resume-zero-output-command", "terminal", { action: "exec", command: "./z.sh" }),
    ]);
    const resumedGateway = startFakeGateway([]);
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(workspace),
        env: {
          ...gatewayEnv(home, initialGateway),
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "session,agent,tool,worker,interrupt,command_output,transcript",
        },
        stderrPath: initialStderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Run the prepared silent command.");
      await waitForCondition(
        () => existsSync(readyPath),
        "the zero-output command readiness file",
        timeout,
      );
      await active.sendKeys("Escape");
      await waitForScrollback(active, "Cancelled", timeout);
      await waitForCondition(
        () => existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=interrupt_persisted"),
        "the zero-output interrupted history event",
        timeout,
      );
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(initialStderrPath, "utf8")).toBe("");

      active = await TmuxSession.create({
        cmd: `${FX_BIN} resume last`,
        cwd: realpathSync(workspace),
        env: gatewayEnv(home, resumedGateway),
        stderrPath: resumedStderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      const resumed = stripAnsi(await waitForScrollback(active, "● System: cancelled", timeout));
      const cancelledIndex = resumed.indexOf("Cancelled");
      const cancellationNoticeIndex = resumed.indexOf("● System: cancelled");
      expect(cancelledIndex).toBeGreaterThanOrEqual(0);
      expect(cancellationNoticeIndex).toBeGreaterThan(cancelledIndex);
      expect(countOccurrences(resumed, "● System: cancelled")).toBe(1);
      expect(resumed).not.toContain("Interrupted by user after completing");
      expect(resumed).not.toContain("<turn_aborted>");
      const restoredPresentation = resumed.slice(cancelledIndex, cancellationNoticeIndex);
      expect(
        restoredPresentation.split("\n").some((line) => line.trimStart().startsWith("│")),
      ).toBe(false);
      expect(restoredPresentation).not.toContain("command lines folded");
      expect(resumedGateway.requests).toHaveLength(0);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      await active.sendKeys("C-o");
      await Bun.sleep(300);
      const fullTranscript = stripAnsi(await active.capturePane());
      expect(fullTranscript).toContain("Cancelled ./z.sh");
      expect(fullTranscript).not.toContain('"command":"./z.sh"');
      expect(fullTranscript).not.toMatch(/^\s*(?:input|result)\s*$/m);
      await active.sendKeys("Escape");
      passed = true;
    } finally {
      if (active) {
        if (!passed) {
          try {
            writeFileSync(join(root, "failure-scrollback.txt"), await active.captureFullScrollback());
          } catch {}
        } else {
          try {
            await active.sendText("/quit");
          } catch {}
        }
        await active.kill();
      }
      initialGateway.stop();
      resumedGateway.stop();
      if (passed) {
        rmSync(root, { recursive: true, force: true });
      } else {
        console.error(`retained zero-output cancelled command resume artifacts at ${root}`);
      }
    }
  },
  120_000,
);
