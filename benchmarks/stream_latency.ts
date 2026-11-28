// Measures how fast a streamed reply shows in the terminal, and how often a frame
// shows markdown markup while the reply is still streaming.
//
// Each run starts fx in tmux against a fake gateway that streams one reply, one
// delta every DELTA_INTERVAL_MS, while the script polls the pane. Per binary it
// reports, as median and p95 over the runs:
//   first word    from the gateway's first write to the first frame that shows a word
//   per-word lag  from the delta that carries a word to the first frame that shows it
//   full reply    from the first write to the first frame that shows the last word
//   raw-mark frames  frames in which a reply row shows markup such as ** or a pipe row
//
//   bun benchmarks/stream_latency.ts --binary <path> [--binary <path> ...]
//     [--runs N] [--scenario s1|s2|s3|s4 ...] [--json <path>]
//
// Binaries take turns, run by run, after WARMUP_RUNS unrecorded launches each, so
// a before-and-after pair sees the same machine state. Needs tmux. Sound is off.

import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../tests/evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  tmuxAvailable,
  TmuxSession,
} from "../tests/e2e/tmux-helpers";

const DELTA_INTERVAL_MS = 30;
const POLL_INTERVAL_MS = 5;
const REPLY_DEADLINE_MS = 30_000;
const COMPOSER_TIMEOUT_MS = 15_000;
const DEFAULT_RUNS = 20;
const WARMUP_RUNS = 2;
const TERMINAL_WIDTH = 120;
const TERMINAL_HEIGHT = 40;

const FINISH_EVENT = {
  type: "finish",
  finishReason: { unified: "stop", raw: "stop" },
  usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
};

const MARKDOWN_REPLY =
  "Streaming **bold words** and `inline code` with a [link](https://example.com) here.\n\n" +
  "## Heading\n\n- item one\n- item two\n\n```zig\nconst x = 1;\n```\n\n" +
  "| a | b |\n|---|---|\n| 1 | 2 |\n\nTitle line\n===\n\nEnd *italic* text.\n";

const LONG_REPLY =
  Array.from({ length: 60 }, (_, i) => {
    const word = `word${String(i + 1).padStart(2, "0")}`;
    const n = i + 1;
    if (n === 30) return `\`${word}\``;
    if (n === 10) return `**${word}`;
    if (n === 12) return `${word}**`;
    return word;
  }).join(" ") + "\n\nDone.\n";

const HISTORY_BURST = Array.from({ length: 80 }, (_, i) => `line ${i + 1}`).join("\n");

// Splits after every space, so each delta keeps its trailing space.
const AFTER_SPACE = /(?<= )/;
// Also splits after a blank line, so "Done." is its own delta.
const AFTER_SPACE_OR_PARAGRAPH = /(?<= )|(?<=\n\n)/;

// One 48-row pipe table, then a fenced block of 50 lines, then "Done.".
function tallPieces(): string[] {
  const rows = Array.from({ length: 48 }, (_, i) => `| r${i + 1} | value ${i + 1} |\n`);
  const code = Array.from({ length: 50 }, (_, i) => `line ${i + 1}\n`);
  return ["| key | value |\n", "|---|---|\n", ...rows, "```\n", ...code, "```\n", "Done.\n"];
}

type History = { prompt: string; text: string; waitFor: string };
type Scenario = {
  id: string;
  name: string;
  prompt: string;
  pieces: string[];
  endMarker: RegExp;
  history?: History;
};

const SCENARIOS: Scenario[] = [
  {
    id: "s1",
    name: "s1-fresh",
    prompt: "latency fresh prompt",
    pieces: MARKDOWN_REPLY.split(AFTER_SPACE),
    endMarker: /End \*?italic\*? text\./,
  },
  {
    id: "s2",
    name: "s2-after-history",
    prompt: "latency second prompt",
    pieces: MARKDOWN_REPLY.split(AFTER_SPACE),
    endMarker: /End \*?italic\*? text\./,
    history: { prompt: "latency history prompt", text: HISTORY_BURST, waitFor: "line 80" },
  },
  {
    id: "s3",
    name: "s3-long-paragraph",
    prompt: "latency paragraph prompt",
    pieces: LONG_REPLY.split(AFTER_SPACE_OR_PARAGRAPH),
    endMarker: /Done\./,
  },
  {
    id: "s4",
    name: "s4-tall-blocks",
    prompt: "latency tall blocks prompt",
    pieces: tallPieces(),
    endMarker: /Done\./,
  },
];

// fx's own rows: the footer has an arrow, and the composer starts with a bar.
const CHROME = /↑|^┃|· /;

// Markup that fx hides while its line is open. A row that shows any of it is a raw-mark row.
const RAW_MARKS: RegExp[] = [
  /\*\*/,
  /`/,
  /\[[^\]]*\]\(/,
  /^\s*={3,}\s*$/,
  /^\s*\|.*\|\s*$/,
];

function normalizeWord(raw: string): string {
  return raw.replace(/[^A-Za-z0-9]/g, "");
}

// The words of one delta, with the marks that fx hides removed.
function deltaWords(delta: string): string[] {
  return delta
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*`]/g, "")
    .split(/\s+/)
    .map(normalizeWord)
    .filter((word) => word.length > 0);
}

type ExpectedWord = { text: string; occurrence: number; delta: number };

// The occurrence number tells a repeated word apart: the Nth copy on screen is the Nth word here.
function expectedWords(pieces: string[]): ExpectedWord[] {
  const seen = new Map<string, number>();
  const words: ExpectedWord[] = [];
  pieces.forEach((piece, delta) => {
    for (const text of deltaWords(piece)) {
      const occurrence = (seen.get(text) ?? 0) + 1;
      seen.set(text, occurrence);
      words.push({ text, occurrence, delta });
    }
  });
  return words;
}

// The reply's rows: the lines below the last line that shows the prompt, minus fx's own rows.
function replyRows(plain: string, prompt: string): string[] {
  const lines = plain.split("\n");
  const start = lines.findLastIndex((line) => line.includes(prompt));
  if (start < 0) return [];
  return lines.slice(start + 1).filter((line) => !CHROME.test(line));
}

function visibleCounts(rows: string[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const row of rows) {
    for (const token of row.split(/\s+/).map(normalizeWord)) {
      if (token.length === 0) continue;
      counts.set(token, (counts.get(token) ?? 0) + 1);
    }
  }
  return counts;
}

function hasRawMark(rows: string[]): boolean {
  return rows.some((row) => RAW_MARKS.some((mark) => mark.test(row)));
}

// The gateway's stream. The send time of each delta goes into deltaTimes.
function pacedReply(pieces: string[], deltaTimes: number[]): Response {
  const encoder = new TextEncoder();
  const events = pieces.map(
    (delta) => `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta })}\n\n`,
  );
  events.push(`data: ${JSON.stringify(FINISH_EVENT)}\n\ndata: [DONE]\n\n`);
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        let next = 0;
        const sendNext = () => {
          deltaTimes.push(performance.now());
          try {
            controller.enqueue(encoder.encode(events[next]));
          } catch {
            // The client closed the stream early, so nothing is left to send.
            return;
          }
          next += 1;
          if (next === events.length) controller.close();
          else setTimeout(sendNext, DELTA_INTERVAL_MS);
        };
        sendNext();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

// Captured without blocking, so the gateway's timer keeps running while tmux answers.
async function capturePane(session: TmuxSession): Promise<string> {
  const proc = Bun.spawn(["tmux", "capture-pane", "-t", session.name, "-p", "-S", "-"], {
    stdout: "pipe",
    stderr: "ignore",
  });
  const text = await new Response(proc.stdout).text();
  return (await proc.exited) === 0 ? text : "";
}

type Frame = { at: number; plain: string };

// Polls the pane until done() is true, keeping each frame that differs from the last.
// Returns the time of the frame that met done, or null at the deadline.
async function pollUntil(
  session: TmuxSession,
  frames: Frame[],
  done: (plain: string) => boolean,
  deadline: number,
): Promise<number | null> {
  let previous: string | null = null;
  while (performance.now() < deadline) {
    const plain = await capturePane(session);
    const at = performance.now();
    if (plain !== previous) {
      previous = plain;
      frames.push({ at, plain });
    }
    if (done(plain)) return at;
    await Bun.sleep(POLL_INTERVAL_MS);
  }
  return null;
}

type Measurement = {
  firstWordMs: number;
  fullReplyMs: number;
  lagsMs: number[];
  measuredFrames: number;
  rawMarkFrames: number;
};

function measure(scenario: Scenario, frames: Frame[], deltaTimes: number[], doneAt: number): Measurement {
  const origin = deltaTimes[0];
  const counts = frames.map((frame) => visibleCounts(replyRows(frame.plain, scenario.prompt)));
  const expected = expectedWords(scenario.pieces);
  const visibleAt = expected.map((word) => {
    const index = counts.findIndex((c) => (c.get(word.text) ?? 0) >= word.occurrence);
    if (index < 0) throw new Error(`word never shown: ${word.text}`);
    return frames[index].at;
  });
  return {
    firstWordMs: visibleAt[0] - origin,
    fullReplyMs: doneAt - origin,
    lagsMs: expected.map((word, i) => visibleAt[i] - deltaTimes[word.delta]),
    measuredFrames: frames.length,
    rawMarkFrames: frames.filter((frame) => hasRawMark(replyRows(frame.plain, scenario.prompt))).length,
  };
}

// Fills the history first, so the measured reply streams below a long scrollback.
async function showHistory(session: TmuxSession, history: History): Promise<void> {
  await session.sendText(history.prompt);
  const deadline = performance.now() + REPLY_DEADLINE_MS;
  const shown = await pollUntil(
    session,
    [],
    (plain) => plain.split("\n").some((line) => line.includes(history.waitFor)),
    deadline,
  );
  if (shown === null) throw new Error(`history: "${history.waitFor}" never appeared`);
}

async function runOnce(binary: string, scenario: Scenario): Promise<Measurement> {
  const home = createIsolatedTestHome();
  const workspace = mkdtempSync(join(tmpdir(), "stream-latency-"));
  const replyStreams: number[][] = [];
  const gateway = startDynamicFakeGateway((body) => {
    if (scenario.history && body.includes(scenario.history.prompt) && !body.includes(scenario.prompt)) {
      return fakeGatewayFinalText(scenario.history.text);
    }
    const deltaTimes: number[] = [];
    replyStreams.push(deltaTimes);
    return pacedReply(scenario.pieces, deltaTimes);
  });
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: binary,
      cwd: workspace,
      width: TERMINAL_WIDTH,
      height: TERMINAL_HEIGHT,
      startupWaitMs: 0,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-stream-latency-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "ask",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
      },
    });
    await session.waitForComposer(COMPOSER_TIMEOUT_MS);
    if (scenario.history) await showHistory(session, scenario.history);

    const frames: Frame[] = [];
    const deadline = performance.now() + REPLY_DEADLINE_MS;
    // Polling starts before the send, so a first paint that lands during the send is kept.
    const replying = pollUntil(
      session,
      frames,
      (plain) => scenario.endMarker.test(replyRows(plain, scenario.prompt).join("\n")),
      deadline,
    );
    await session.sendText(scenario.prompt);
    const doneAt = await replying;
    if (doneAt === null) throw new Error("the reply never finished on screen");
    const deltaTimes = replyStreams.at(-1);
    if (!deltaTimes) throw new Error("no reply reached the fake gateway");
    return measure(scenario, frames, deltaTimes, doneAt);
  } finally {
    await session?.kill();
    gateway.stop();
    cleanupIsolatedTestHome(home);
    rmSync(workspace, { recursive: true, force: true });
  }
}

type Summary = { median: number; p95: number };

function summarize(values: number[]): Summary {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const median = sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  return { median, p95: sorted[Math.ceil(0.95 * sorted.length) - 1] };
}

type Report = {
  binaries: string[];
  runs: number;
  warmupRuns: number;
  scenarios: Array<{ id: string; name: string; measured: Measurement[][] }>;
};

const ms = (value: number) => value.toFixed(1);
const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);

function printReport(report: Report): void {
  for (const scenario of report.scenarios) {
    console.log(`\n### ${scenario.name}: ${report.runs} runs per binary after ${report.warmupRuns} warm-ups (ms)\n`);
    console.log("| binary | first word p50 | p95 | full reply p50 | p95 | per-word lag p50 | p95 | raw-mark frames |");
    console.log("|---|---|---|---|---|---|---|---|");
    scenario.measured.forEach((runs, i) => {
      const first = summarize(runs.map((m) => m.firstWordMs));
      const full = summarize(runs.map((m) => m.fullReplyMs));
      const lag = summarize(runs.flatMap((m) => m.lagsMs));
      const rawFrames = sum(runs.map((m) => m.rawMarkFrames));
      const frames = sum(runs.map((m) => m.measuredFrames));
      console.log(
        `| ${report.binaries[i]} | ${ms(first.median)} | ${ms(first.p95)} | ${ms(full.median)} | ${ms(full.p95)} ` +
          `| ${ms(lag.median)} | ${ms(lag.p95)} | ${rawFrames} of ${frames} |`,
      );
    });
  }
}

function positiveInteger(raw: string): number {
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`expected a positive integer, got ${raw}`);
  return value;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      binary: { type: "string", multiple: true },
      runs: { type: "string" },
      scenario: { type: "string", multiple: true },
      json: { type: "string" },
    },
    strict: true,
  });
  const binaries = (values.binary ?? []).map((path) => resolve(path));
  if (binaries.length === 0) throw new Error("pass at least one --binary <path>");
  for (const path of binaries) {
    if (!existsSync(path)) throw new Error(`binary not found: ${path}`);
  }
  if (!tmuxAvailable()) throw new Error("tmux is required");
  const runs = values.runs === undefined ? DEFAULT_RUNS : positiveInteger(values.runs);
  const scenarios = (values.scenario ?? SCENARIOS.map((s) => s.id)).map((id) => {
    const scenario = SCENARIOS.find((s) => s.id === id);
    if (!scenario) throw new Error(`unknown scenario ${id}: use s1, s2, s3 or s4`);
    return scenario;
  });

  const report: Report = { binaries, runs, warmupRuns: WARMUP_RUNS, scenarios: [] };
  for (const scenario of scenarios) {
    const measured: Measurement[][] = binaries.map(() => []);
    for (let turn = 0; turn < WARMUP_RUNS + runs; turn += 1) {
      const warmup = turn < WARMUP_RUNS;
      for (const [i, binary] of binaries.entries()) {
        const result = await runOnce(binary, scenario);
        if (!warmup) measured[i].push(result);
        console.error(`${scenario.id} turn ${turn}${warmup ? " (warm-up)" : ""} ${binary}: first word ${ms(result.firstWordMs)} ms`);
      }
    }
    report.scenarios.push({ id: scenario.id, name: scenario.name, measured });
  }
  printReport(report);
  if (values.json) writeFileSync(values.json, `${JSON.stringify(report, null, 2)}\n`);
}

await main();
